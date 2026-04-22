import Foundation

/// Generates the JavaScript bridge injected into the page.
///
/// This stays internal to the package, but is split into its own file because
/// it is effectively a separate runtime component from the native Swift code.
package enum ApproovWebViewJavaScriptBridge {
    private static let handlerPlaceholder = "__APPROOV_BRIDGE_HANDLER__"
    private static let protectedEndpointsPlaceholder = "__APPROOV_PROTECTED_ENDPOINTS__"
    private static let xhrBridgeEnabledPlaceholder = "__APPROOV_XHR_BRIDGE_ENABLED__"

    package static func scriptSource(
        handlerName: String,
        protectedEndpoints: [ApproovWebViewProtectedEndpoint],
        xhrBridgeEnabled: Bool
    ) -> String {
        template
            .replacingOccurrences(of: handlerPlaceholder, with: handlerName)
            .replacingOccurrences(
                of: protectedEndpointsPlaceholder,
                with: protectedEndpointsJSON(protectedEndpoints)
            )
            .replacingOccurrences(
                of: xhrBridgeEnabledPlaceholder,
                with: xhrBridgeEnabled ? "true" : "false"
            )
    }

    private static func protectedEndpointsJSON(
        _ protectedEndpoints: [ApproovWebViewProtectedEndpoint]
    ) -> String {
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(protectedEndpoints),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }

        return json
    }

    private static let template = #"""
    (() => {
      const nativeHandler = window.webkit?.messageHandlers?.__APPROOV_BRIDGE_HANDLER__;
      const protectedEndpoints = __APPROOV_PROTECTED_ENDPOINTS__;
      const xhrBridgeEnabled = __APPROOV_XHR_BRIDGE_ENABLED__;
      if (!nativeHandler || typeof nativeHandler.postMessage !== "function") {
        return;
      }

      const originalFetch = window.fetch.bind(window);
      const OriginalXMLHttpRequest = window.XMLHttpRequest;
      const originalFormSubmit = HTMLFormElement.prototype.submit;
      const originalRequestSubmit = HTMLFormElement.prototype.requestSubmit
        ? HTMLFormElement.prototype.requestSubmit
        : null;
      const submitterByForm = new WeakMap();
      const textDecoder = new TextDecoder();

      // Serializes arbitrary request bodies into base64 so Swift receives the
      // exact bytes JavaScript intended to place on the network.
      const arrayBufferToBase64 = (buffer) => {
        const bytes = new Uint8Array(buffer);
        const chunkSize = 0x8000;
        let binary = "";

        for (let index = 0; index < bytes.length; index += chunkSize) {
          const chunk = bytes.subarray(index, index + chunkSize);
          binary += String.fromCharCode(...chunk);
        }

        return btoa(binary);
      };

      // Reconstructs the response body returned from Swift.
      const base64ToUint8Array = (base64Value) => {
        const binary = atob(base64Value || "");
        const bytes = new Uint8Array(binary.length);

        for (let index = 0; index < binary.length; index += 1) {
          bytes[index] = binary.charCodeAt(index);
        }

        return bytes;
      };

      // Only proxy ordinary HTTP(S) traffic. Browser-only schemes such as
      // `data:` or `blob:` should keep using the browser stack directly.
      const matchesPathPrefix = (pathname, pathPrefix) => {
        const normalizedPathPrefix = pathPrefix || "/";
        return normalizedPathPrefix === "/"
          ? true
          : pathname === normalizedPathPrefix || pathname.startsWith(`${normalizedPathPrefix}/`);
      };

      const isProtectedEndpoint = (urlString) => {
        try {
          const resolvedURL = new URL(urlString, window.location.href);
          if (resolvedURL.protocol !== "http:" && resolvedURL.protocol !== "https:") {
            return false;
          }

          const hostname = resolvedURL.hostname.toLowerCase();
          const pathname = resolvedURL.pathname || "/";
          return protectedEndpoints.some((entry) => {
            const excludedPathPrefixes = Array.isArray(entry.excludedPathPrefixes)
              ? entry.excludedPathPrefixes
              : [];
            const schemeMatches = resolvedURL.protocol === `${entry.scheme}:`;
            const hostMatches = hostname === entry.host;
            const pathMatches = matchesPathPrefix(pathname, entry.pathPrefix);
            const pathExcluded = excludedPathPrefixes.some((excludedPathPrefix) =>
              matchesPathPrefix(pathname, excludedPathPrefix)
            );
            return schemeMatches && hostMatches && pathMatches && !pathExcluded;
          });
        } catch (_error) {
          return false;
        }
      };

      const serializeRequest = async (request, requestSource, responseHandling) => {
        const headers = {};
        request.headers.forEach((value, key) => {
          headers[key] = value;
        });

        let bodyBase64 = null;
        if (request.method !== "GET" && request.method !== "HEAD") {
          const bodyBuffer = await request.clone().arrayBuffer();
          bodyBase64 = bodyBuffer.byteLength === 0 ? null : arrayBufferToBase64(bodyBuffer);
        }

        return {
          url: request.url,
          method: request.method,
          headers,
          bodyBase64,
          sourcePageURL: window.location.href,
          responseHandling,
          requestSource,
        };
      };

      const serializeBody = async (bodyValue) => {
        if (bodyValue == null) {
          return null;
        }

        const request = new Request("https://approov.invalid/body", {
          method: "POST",
          body: bodyValue,
        });

        const bodyBuffer = await request.arrayBuffer();
        return bodyBuffer.byteLength === 0 ? null : arrayBufferToBase64(bodyBuffer);
      };

      const makeFetchResponse = (nativeResponse) => {
        const responseBytes = base64ToUint8Array(nativeResponse.bodyBase64);
        return new Response(responseBytes, {
          status: nativeResponse.status,
          statusText: nativeResponse.statusText,
          headers: nativeResponse.headers,
        });
      };

      const postDiagnostic = (payload) => {
        try {
          Promise.resolve(nativeHandler.postMessage({
            kind: "diagnostic",
            ...payload,
          })).catch(() => {});
        } catch (_error) {
          // Diagnostic logging must never interfere with page traffic.
        }
      };

      const logUnprotectedRequestBypass = (requestSource, urlString) => {
        postDiagnostic({
          event: "unprotected-request-bypass",
          requestSource,
          url: urlString,
        });
      };

      const dispatchFormEvent = (form, eventName, detail) => {
        form.dispatchEvent(new CustomEvent(eventName, {
          bubbles: true,
          detail,
        }));
      };

      const resolveFormAction = (form, submitter) => {
        const rawAction = submitter?.getAttribute("formaction")
          || form.getAttribute("action")
          || window.location.href;

        return new URL(rawAction, window.location.href).toString();
      };

      const resolveFormMethod = (form, submitter) => {
        const rawMethod = submitter?.getAttribute("formmethod")
          || form.getAttribute("method")
          || "GET";
        return rawMethod.toUpperCase();
      };

      const resolveFormEnctype = (form, submitter) => {
        const rawEnctype = submitter?.getAttribute("formenctype")
          || form.getAttribute("enctype")
          || "application/x-www-form-urlencoded";
        return rawEnctype.toLowerCase();
      };

      const resolveFormTarget = (form, submitter) => {
        const rawTarget = submitter?.getAttribute("formtarget")
          || form.getAttribute("target")
          || "_self";
        return rawTarget.toLowerCase();
      };

      const resolveFormResponseHandling = (form) => {
        const requestedMode = (form.dataset.approovSubmitMode || "navigation").toLowerCase();
        return requestedMode === "response" ? "response" : "navigation";
      };

      const appendSubmitterToFormData = (formData, submitter) => {
        if (submitter && submitter.name) {
          formData.append(submitter.name, submitter.value || "");
        }
      };

      const appendFormValueToSearchParams = (searchParams, name, value) => {
        if (value instanceof File) {
          searchParams.append(name, value.name);
          return;
        }

        searchParams.append(name, value);
      };

      const encodeTextPlainFormData = (formData) => {
        const lines = [];

        formData.forEach((value, name) => {
          if (value instanceof File) {
            lines.push(`${name}=${value.name}`);
            return;
          }

          lines.push(`${name}=${value}`);
        });

        return lines.join("\r\n");
      };

      const serializeFormSubmission = async (form, submitter) => {
        const method = resolveFormMethod(form, submitter);
        const enctype = resolveFormEnctype(form, submitter);
        const actionURL = resolveFormAction(form, submitter);
        const responseHandling = resolveFormResponseHandling(form);
        const formData = new FormData(form);

        appendSubmitterToFormData(formData, submitter);

        let requestURL = new URL(actionURL);
        let body = null;

        if (method === "GET" || method === "HEAD") {
          const query = new URLSearchParams(requestURL.search);
          formData.forEach((value, name) => {
            appendFormValueToSearchParams(query, name, value);
          });
          requestURL.search = query.toString();
        } else {
          switch (enctype) {
            case "multipart/form-data":
              body = formData;
              break;
            case "text/plain":
              body = encodeTextPlainFormData(formData);
              break;
            case "application/x-www-form-urlencoded":
            default: {
              const searchParams = new URLSearchParams();
              formData.forEach((value, name) => {
                appendFormValueToSearchParams(searchParams, name, value);
              });
              body = searchParams;
              break;
            }
          }
        }

        const request = new Request(requestURL.toString(), {
          method,
          body,
          headers: {
            // HTML form navigations typically expect a document response.
            Accept: responseHandling === "navigation"
              ? "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
              : "*/*",
          },
        });

        return serializeRequest(request, "form", responseHandling);
      };

      const isSubmitControl = (element) => {
        if (element instanceof HTMLButtonElement) {
          return element.type === "submit" || element.type === "";
        }

        if (element instanceof HTMLInputElement) {
          return element.type === "submit";
        }

        return false;
      };

      const isNativeHandledForm = (form, submitter) => {
        const method = resolveFormMethod(form, submitter);
        if (method === "DIALOG") {
          return false;
        }

        const actionURL = resolveFormAction(form, submitter);
        if (!isProtectedEndpoint(actionURL)) {
          logUnprotectedRequestBypass("form", actionURL);
          return false;
        }

        // Current-frame form submission is the production-safe path that can
        // be modeled with `loadSimulatedRequest(...)`.
        const target = resolveFormTarget(form, submitter);
        return target === "" || target === "_self";
      };

      const handleNativeFormResponse = (form, nativeResponse) => {
        const bodyBytes = base64ToUint8Array(nativeResponse.bodyBase64);
        const bodyText = textDecoder.decode(bodyBytes);

        dispatchFormEvent(form, "approov:form-response", {
          url: nativeResponse.url,
          status: nativeResponse.status,
          statusText: nativeResponse.statusText,
          ok: nativeResponse.status >= 200 && nativeResponse.status < 300,
          headers: nativeResponse.headers,
          bodyText,
          bodyBase64: nativeResponse.bodyBase64,
        });
      };

      const handleNativeFormError = (form, error) => {
        const message = error?.message || String(error);
        dispatchFormEvent(form, "approov:form-error", {
          message,
        });
      };

      const proxyFormSubmission = async (form, submitter) => {
        if (form.dataset.approovSubmitting === "true") {
          return;
        }

        form.dataset.approovSubmitting = "true";

        try {
          const payload = await serializeFormSubmission(form, submitter);
          const nativeResponse = await nativeHandler.postMessage(payload);

          if (payload.responseHandling === "response") {
            handleNativeFormResponse(form, nativeResponse);
          }
        } catch (error) {
          handleNativeFormError(form, error);
        } finally {
          delete form.dataset.approovSubmitting;
          submitterByForm.delete(form);
        }
      };

      // Replace Fetch with a transparent native proxy. Page code still calls
      // `fetch(...)` as normal and receives a normal `Response`.
      window.fetch = async (input, init) => {
        const request = input instanceof Request && init === undefined
          ? input
          : new Request(input, init);

        if (!isProtectedEndpoint(request.url)) {
          logUnprotectedRequestBypass("fetch", request.url);
          return originalFetch(input, init);
        }

        const payload = await serializeRequest(
          request,
          "fetch",
          "response",
        );
        const nativeResponse = await nativeHandler.postMessage(payload);
        return makeFetchResponse(nativeResponse);
      };

      const makeXHREvent = (type, detail = null) => {
        const event = new Event(type);
        event.detail = detail;
        return event;
      };

      const getXMLHttpRequestDescriptor = (propertyName) => {
        let prototype = OriginalXMLHttpRequest.prototype;

        while (prototype) {
          const descriptor = Object.getOwnPropertyDescriptor(prototype, propertyName);
          if (descriptor) {
            return descriptor;
          }

          prototype = Object.getPrototypeOf(prototype);
        }

        return null;
      };

      const getNativeXMLHttpRequestProperty = (xhr, propertyName) => {
        const descriptor = getXMLHttpRequestDescriptor(propertyName);
        if (descriptor?.get) {
          return descriptor.get.call(xhr);
        }

        return xhr[propertyName];
      };

      const setNativeXMLHttpRequestProperty = (xhr, propertyName, value) => {
        const descriptor = getXMLHttpRequestDescriptor(propertyName);
        if (descriptor?.set) {
          descriptor.set.call(xhr, value);
          return;
        }

        xhr[propertyName] = value;
      };

      const applyProtectedXHRResponseBody = (protectedState, responseBytes) => {
        switch (protectedState.responseType) {
          case "arraybuffer":
            protectedState.response = responseBytes.buffer;
            protectedState.responseText = "";
            break;
          case "blob":
            protectedState.response = new Blob([responseBytes]);
            protectedState.responseText = "";
            break;
          case "json": {
            const textValue = textDecoder.decode(responseBytes);
            protectedState.responseText = textValue;
            protectedState.response = textValue ? JSON.parse(textValue) : null;
            break;
          }
          case "":
          case "text":
          default: {
            const textValue = textDecoder.decode(responseBytes);
            protectedState.responseText = textValue;
            protectedState.response = textValue;
          }
        }
      };

      // Preserve the native XHR surface for unprotected traffic and switch an
      // individual instance into synthetic mode only when it opens a protected
      // endpoint. This avoids breaking WebKit-only XHR behavior on pages that
      // never needed Approov interception in the first place.
      function ApproovXMLHttpRequest() {
        const xhr = new OriginalXMLHttpRequest();
        const nativeOpen = xhr.open.bind(xhr);
        const nativeSend = xhr.send.bind(xhr);
        const nativeAbort = xhr.abort.bind(xhr);
        const nativeSetRequestHeader = xhr.setRequestHeader.bind(xhr);
        const nativeGetResponseHeader = xhr.getResponseHeader.bind(xhr);
        const nativeGetAllResponseHeaders = xhr.getAllResponseHeaders.bind(xhr);
        const nativeOverrideMimeType = typeof xhr.overrideMimeType === "function"
          ? xhr.overrideMimeType.bind(xhr)
          : null;
        const protectedState = {
          active: false,
          aborted: false,
          headers: {},
          method: "GET",
          overrideMimeType: null,
          readyState: 0,
          response: null,
          responseHeaders: {},
          responseText: "",
          responseType: getNativeXMLHttpRequestProperty(xhr, "responseType") || "",
          responseURL: "",
          status: 0,
          statusText: "",
          timeout: getNativeXMLHttpRequestProperty(xhr, "timeout") || 0,
          url: "",
          withCredentials: getNativeXMLHttpRequestProperty(xhr, "withCredentials") || false,
        };

        const changeProtectedReadyState = (nextState) => {
          protectedState.readyState = nextState;
          xhr.dispatchEvent(makeXHREvent("readystatechange"));
        };

        Object.defineProperties(xhr, {
          readyState: {
            configurable: true,
            enumerable: true,
            get() {
              return protectedState.active
                ? protectedState.readyState
                : getNativeXMLHttpRequestProperty(xhr, "readyState");
            },
          },
          status: {
            configurable: true,
            enumerable: true,
            get() {
              return protectedState.active
                ? protectedState.status
                : getNativeXMLHttpRequestProperty(xhr, "status");
            },
          },
          statusText: {
            configurable: true,
            enumerable: true,
            get() {
              return protectedState.active
                ? protectedState.statusText
                : getNativeXMLHttpRequestProperty(xhr, "statusText");
            },
          },
          response: {
            configurable: true,
            enumerable: true,
            get() {
              return protectedState.active
                ? protectedState.response
                : getNativeXMLHttpRequestProperty(xhr, "response");
            },
          },
          responseText: {
            configurable: true,
            enumerable: true,
            get() {
              return protectedState.active
                ? protectedState.responseText
                : getNativeXMLHttpRequestProperty(xhr, "responseText");
            },
          },
          responseType: {
            configurable: true,
            enumerable: true,
            get() {
              return protectedState.active
                ? protectedState.responseType
                : getNativeXMLHttpRequestProperty(xhr, "responseType");
            },
            set(value) {
              if (protectedState.active) {
                protectedState.responseType = value || "";
                return;
              }

              setNativeXMLHttpRequestProperty(xhr, "responseType", value);
            },
          },
          responseURL: {
            configurable: true,
            enumerable: true,
            get() {
              return protectedState.active
                ? protectedState.responseURL
                : getNativeXMLHttpRequestProperty(xhr, "responseURL");
            },
          },
          responseXML: {
            configurable: true,
            enumerable: true,
            get() {
              return protectedState.active
                ? null
                : getNativeXMLHttpRequestProperty(xhr, "responseXML");
            },
          },
          timeout: {
            configurable: true,
            enumerable: true,
            get() {
              return protectedState.active
                ? protectedState.timeout
                : getNativeXMLHttpRequestProperty(xhr, "timeout");
            },
            set(value) {
              if (protectedState.active) {
                protectedState.timeout = Number(value) || 0;
                return;
              }

              setNativeXMLHttpRequestProperty(xhr, "timeout", value);
            },
          },
          withCredentials: {
            configurable: true,
            enumerable: true,
            get() {
              return protectedState.active
                ? protectedState.withCredentials
                : getNativeXMLHttpRequestProperty(xhr, "withCredentials");
            },
            set(value) {
              if (protectedState.active) {
                protectedState.withCredentials = Boolean(value);
                return;
              }

              setNativeXMLHttpRequestProperty(xhr, "withCredentials", value);
            },
          },
        });

        xhr.open = (method, url, async = true, user = null, password = null) => {
          const resolvedURL = new URL(url, window.location.href).toString();

          protectedState.aborted = false;
          protectedState.active = false;
          protectedState.headers = {};
          protectedState.method = (method || "GET").toUpperCase();
          protectedState.overrideMimeType = null;
          protectedState.readyState = 0;
          protectedState.response = null;
          protectedState.responseHeaders = {};
          protectedState.responseText = "";
          protectedState.responseType = getNativeXMLHttpRequestProperty(xhr, "responseType") || "";
          protectedState.responseURL = "";
          protectedState.status = 0;
          protectedState.statusText = "";
          protectedState.timeout = getNativeXMLHttpRequestProperty(xhr, "timeout") || 0;
          protectedState.url = resolvedURL;
          protectedState.withCredentials =
            getNativeXMLHttpRequestProperty(xhr, "withCredentials") || false;

          if (!isProtectedEndpoint(resolvedURL)) {
            logUnprotectedRequestBypass("xhr", resolvedURL);
            return nativeOpen(method, url, async, user, password);
          }

          if (async === false) {
            throw new DOMException(
              "Synchronous XMLHttpRequest is not supported for protected endpoints.",
              "NotSupportedError",
            );
          }

          protectedState.active = true;
          changeProtectedReadyState(1);
        };

        xhr.setRequestHeader = (name, value) => {
          if (!protectedState.active) {
            nativeSetRequestHeader(name, value);
            return;
          }

          protectedState.headers[name] = value;
        };

        xhr.getResponseHeader = (name) => {
          if (!protectedState.active) {
            return nativeGetResponseHeader(name);
          }

          return protectedState.responseHeaders[name.toLowerCase()] || null;
        };

        xhr.getAllResponseHeaders = () => {
          if (!protectedState.active) {
            return nativeGetAllResponseHeaders();
          }

          return Object.entries(protectedState.responseHeaders)
            .map(([name, value]) => `${name}: ${value}`)
            .join("\r\n");
        };

        if (nativeOverrideMimeType) {
          xhr.overrideMimeType = (mimeType) => {
            if (!protectedState.active) {
              nativeOverrideMimeType(mimeType);
              return;
            }

            protectedState.overrideMimeType = mimeType;
          };
        }

        xhr.abort = () => {
          if (!protectedState.active) {
            nativeAbort();
            return;
          }

          if (protectedState.readyState === 0 || protectedState.readyState === 4) {
            return;
          }

          protectedState.aborted = true;
          protectedState.readyState = 0;
          protectedState.response = null;
          protectedState.responseHeaders = {};
          protectedState.responseText = "";
          protectedState.responseURL = "";
          protectedState.status = 0;
          protectedState.statusText = "";
          xhr.dispatchEvent(makeXHREvent("abort"));
          xhr.dispatchEvent(makeXHREvent("loadend"));
        };

        xhr.send = async (body = null) => {
          if (!protectedState.active) {
            nativeSend(body);
            return;
          }

          try {
            const nativeResponse = await nativeHandler.postMessage({
              url: protectedState.url,
              method: protectedState.method,
              headers: protectedState.headers,
              bodyBase64: await serializeBody(body),
              sourcePageURL: window.location.href,
              responseHandling: "response",
              requestSource: "xhr",
            });

            if (protectedState.aborted || !protectedState.active) {
              return;
            }

            protectedState.status = nativeResponse.status;
            protectedState.statusText = nativeResponse.statusText;
            protectedState.responseURL = nativeResponse.url || protectedState.url;
            protectedState.responseHeaders = Object.fromEntries(
              Object.entries(nativeResponse.headers).map(([name, value]) => [name.toLowerCase(), value]),
            );

            changeProtectedReadyState(2);
            changeProtectedReadyState(3);
            applyProtectedXHRResponseBody(
              protectedState,
              base64ToUint8Array(nativeResponse.bodyBase64),
            );
            changeProtectedReadyState(4);
            xhr.dispatchEvent(makeXHREvent("load"));
            xhr.dispatchEvent(makeXHREvent("loadend"));
          } catch (error) {
            if (protectedState.aborted || !protectedState.active) {
              return;
            }

            changeProtectedReadyState(4);
            xhr.dispatchEvent(makeXHREvent("error", error));
            xhr.dispatchEvent(makeXHREvent("loadend"));
          }
        };

        return xhr;
      }

      ["UNSENT", "OPENED", "HEADERS_RECEIVED", "LOADING", "DONE"].forEach((name) => {
        const value = OriginalXMLHttpRequest[name];
        if (typeof value !== "number") {
          return;
        }

        Object.defineProperty(ApproovXMLHttpRequest, name, {
          configurable: true,
          enumerable: true,
          value,
          writable: false,
        });
      });

      document.addEventListener("click", (event) => {
        const clickedElement = event.target instanceof Element
          ? event.target.closest("button, input")
          : null;

        if (!isSubmitControl(clickedElement) || !clickedElement.form) {
          return;
        }

        submitterByForm.set(clickedElement.form, clickedElement);
      }, true);

      document.addEventListener("submit", (event) => {
        const form = event.target;
        if (!(form instanceof HTMLFormElement)) {
          return;
        }

        const submitter = event.submitter || submitterByForm.get(form) || null;
        if (!isNativeHandledForm(form, submitter)) {
          return;
        }

        event.preventDefault();
        void proxyFormSubmission(form, submitter);
      }, true);

      // `form.submit()` bypasses the normal submit event, so it must be wrapped
      // explicitly if programmatic submission should also be protected.
      HTMLFormElement.prototype.submit = function () {
        const form = this;
        const submitter = submitterByForm.get(form) || null;

        if (!isNativeHandledForm(form, submitter)) {
          return originalFormSubmit.call(form);
        }

        void proxyFormSubmission(form, submitter);
      };

      // Keep `requestSubmit()` semantics intact but remember the submitter so
      // the subsequent `submit` event sees the correct form overrides.
      if (originalRequestSubmit) {
        HTMLFormElement.prototype.requestSubmit = function (submitter) {
          if (submitter) {
            submitterByForm.set(this, submitter);
          }

          return originalRequestSubmit.call(this, submitter);
        };
      }

      if (xhrBridgeEnabled) {
        window.XMLHttpRequest = ApproovXMLHttpRequest;
        window.XMLHttpRequest.prototype = OriginalXMLHttpRequest.prototype;
      }
      window.__approovBridgeEnabled = true;
      window.__approovBridgeFeatures = {
        fetch: true,
        xhr: xhrBridgeEnabled,
        forms: true,
        cookieSync: true,
        simulatedNavigations: true,
      };
    })();
    """#
}
