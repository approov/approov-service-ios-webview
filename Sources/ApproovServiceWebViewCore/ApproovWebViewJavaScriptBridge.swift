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
        xhrBridgeEnabled: Bool,
        maxRequestBodyBytes: Int = 10 * 1024 * 1024
    ) -> String {
        template
            .replacingOccurrences(of: handlerPlaceholder, with: String(decoding: try! JSONEncoder().encode(handlerName), as: UTF8.self))
            .replacingOccurrences(
                of: protectedEndpointsPlaceholder,
                with: protectedEndpointsJSON(protectedEndpoints)
            )
            .replacingOccurrences(
                of: xhrBridgeEnabledPlaceholder,
                with: xhrBridgeEnabled ? "true" : "false"
            )
            .replacingOccurrences(of: "__APPROOV_MAX_REQUEST_BODY_BYTES__", with: String(max(0, maxRequestBodyBytes)))
    }

    private static func protectedEndpointsJSON(
        _ protectedEndpoints: [ApproovWebViewProtectedEndpoint]
    ) -> String {
        let encoder = JSONEncoder()
        // The generated source is also the installation identity used by
        // ApproovWebViewFactory. JSON object key order is not significant and
        // JSONEncoder does not otherwise promise one, so sort keys to ensure
        // identical configurations always produce identical source.
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(protectedEndpoints),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }

        return json
    }

    private static let template = #"""
    (() => {
      const nativeHandler = window.webkit?.messageHandlers?.[__APPROOV_BRIDGE_HANDLER__];
      const protectedEndpoints = __APPROOV_PROTECTED_ENDPOINTS__;
      const xhrBridgeEnabled = __APPROOV_XHR_BRIDGE_ENABLED__;
      const maxRequestBodyBytes = __APPROOV_MAX_REQUEST_BODY_BYTES__;
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

      const canonicalPath = (path) => path.replace(/%([0-9a-f]{2})/gi, (_, hex) => {
        const character = String.fromCharCode(parseInt(hex, 16));
        return /^[A-Za-z0-9._~-]$/.test(character) ? character : `%${hex.toUpperCase()}`;
      });

      const isProtectedEndpoint = (urlString) => {
        let resolvedURL;
        try { resolvedURL = new URL(urlString, document.baseURI); } catch (_) { return false; }
        if (!["http:", "https:"].includes(resolvedURL.protocol)) return false;
        const defaultPort = resolvedURL.protocol === "https:" ? 443 : 80;
        const entries = protectedEndpoints.filter(entry => resolvedURL.protocol === `${entry.scheme}:` &&
          resolvedURL.hostname.toLowerCase() === entry.host &&
          Number(resolvedURL.port || defaultPort) === (entry.port ?? defaultPort));
        if (!entries.length) return false;
        // URL parsing removes dot segments. Inspect the original spelling too,
        // so encoded separators/dot segments cannot escape a protected rule.
        const rawPath = String(urlString).split(/[?#]/, 1)[0]
          .replace(/^(?:[A-Za-z][A-Za-z0-9+.-]*:)?\/\/[^/\\]*/, "");
        const ambiguous = path => /%(?![0-9a-f]{2})|%2f|%5c|\\/i.test(path) ||
          path.split("/").some(segment => segment.includes("%") && [".", ".."].includes(canonicalPath(segment)));
        if (ambiguous(rawPath) || ambiguous(resolvedURL.pathname)) {
          throw new TypeError("Ambiguous protected URL path is not supported");
        }
        const pathname = canonicalPath(resolvedURL.pathname || "/");
        return entries.some(entry => {
          const excludedPathPrefixes = Array.isArray(entry.excludedPathPrefixes) ? entry.excludedPathPrefixes : [];
          return matchesPathPrefix(pathname, canonicalPath(entry.pathPrefix || "/")) &&
            !excludedPathPrefixes.some(excludedPathPrefix => matchesPathPrefix(pathname, canonicalPath(excludedPathPrefix)));
        });
      };

      // The bridge supports finite, buffered bodies. Stop reading as soon as
      // the byte limit is crossed, before allocating the base64 representation.
      const readRequestBody = async (request) => {
        if (!request.body) return new ArrayBuffer(0);
        const reader = request.body.getReader();
        const chunks = [];
        let length = 0;
        try {
          while (true) {
            const { done, value } = await reader.read();
            if (done) break;
            length += value.byteLength;
            if (length > maxRequestBodyBytes) {
              await reader.cancel("Protected request body exceeds the configured byte limit");
              throw new TypeError("Protected request body exceeds the configured byte limit");
            }
            chunks.push(value);
          }
        } finally {
          reader.releaseLock();
        }
        const bytes = new Uint8Array(length);
        let offset = 0;
        for (const chunk of chunks) { bytes.set(chunk, offset); offset += chunk.byteLength; }
        return bytes.buffer;
      };

      const serializeRequest = async (request, requestSource, responseHandling) => {
        const headers = {};
        request.headers.forEach((value, key) => {
          headers[key] = value;
        });

        let bodyBase64 = null;
        if (request.method !== "GET" && request.method !== "HEAD") {
          const bodyBuffer = await readRequestBody(request);
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
          credentials: request.credentials,
          mode: request.mode,
          redirect: request.redirect,
          cache: request.cache,
          integrity: request.integrity,
          referrer: request.referrer,
          referrerPolicy: request.referrerPolicy,
        };
      };

      const serializeBody = async (bodyValue) => {
        if (bodyValue == null) return { bodyBase64: null, contentType: null, byteLength: 0 };
        let contentType = null;
        if (bodyValue instanceof Document) {
          contentType = bodyValue.contentType === "text/html" ? "text/html;charset=UTF-8" : "application/xml;charset=UTF-8";
          bodyValue = new XMLSerializer().serializeToString(bodyValue);
        }
        const request = new Request("https://approov.invalid/body", { method: "POST", body: bodyValue });
        const bodyBuffer = await readRequestBody(request);
        return {
          bodyBase64: bodyBuffer.byteLength === 0 ? null : arrayBufferToBase64(bodyBuffer),
          contentType: contentType || request.headers.get("content-type"),
          byteLength: bodyBuffer.byteLength,
        };
      };

      const makeFetchResponse = (nativeResponse, requestMethod) => {
        const responseBytes = base64ToUint8Array(nativeResponse.bodyBase64);
        const nullBody = requestMethod === "HEAD" || [204, 205, 304].includes(nativeResponse.status);
        const decorate = (response) => {
          const clone = response.clone.bind(response);
          Object.defineProperties(response, {
            url: { value: nativeResponse.url || "", enumerable: true },
            redirected: { value: Boolean(nativeResponse.redirected), enumerable: true },
            type: { value: nativeResponse.type || "basic", enumerable: true },
            clone: { value: () => decorate(clone()) },
          });
          for (const name of ["append", "delete", "set"]) {
            Object.defineProperty(response.headers, name, {
              value: () => { throw new TypeError("Response headers are immutable"); },
            });
          }
          return response;
        };
        return decorate(new Response(nullBody ? null : responseBytes, {
          status: nativeResponse.status,
          statusText: nativeResponse.statusText,
          headers: nativeResponse.headers,
        }));
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

        isProtectedEndpoint(rawAction); // Reject ambiguous spelling before URL normalization.
        return new URL(rawAction, document.baseURI).toString();
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
      let nextRequestID = 0;
      const allocateRequestID = () => `${Date.now()}-${++nextRequestID}-${Math.random().toString(36).slice(2)}`;
      window.fetch = async (input, init) => {
        const inputURL = input instanceof Request ? input.url : String(input);
        if (!isProtectedEndpoint(inputURL)) {
          const bypassURL = new URL(inputURL, document.baseURI).toString();
          logUnprotectedRequestBypass("fetch", bypassURL);
          return originalFetch(input, init);
        }
        const request = input instanceof Request && init === undefined ? input : new Request(input, init);

        if (request.mode === "no-cors" || request.redirect === "manual" || request.integrity ||
            (typeof ReadableStream !== "undefined" && init?.body instanceof ReadableStream)) {
          throw new TypeError("This protected fetch option is not supported");
        }
        const requestId = allocateRequestID();
        const signal = request.signal;
        if (signal.aborted) throw signal.reason || new DOMException("Aborted", "AbortError");
        let sent = false;
        let onAbort;
        const aborted = new Promise((_, reject) => {
          onAbort = () => {
            if (sent) {
              Promise.resolve(nativeHandler.postMessage({ kind: "cancel", requestId })).catch(() => {});
            }
            reject(signal.reason || new DOMException("Aborted", "AbortError"));
          };
          signal.addEventListener("abort", onAbort, { once: true });
        });
        try {
          const payload = await Promise.race([serializeRequest(request, "fetch", "response"), aborted]);
          if (signal.aborted) throw signal.reason || new DOMException("Aborted", "AbortError");
          payload.requestId = requestId;
          sent = true;
          const nativeReply = Promise.resolve(nativeHandler.postMessage(payload)).catch(() => {
            throw new TypeError("Protected fetch failed");
          });
          const nativeResponse = await Promise.race([nativeReply, aborted]);
          return makeFetchResponse(nativeResponse, request.method);
        } finally {
          signal.removeEventListener("abort", onAbort);
        }
      };

      const makeXHREvent = (type, loaded = 0, total = 0, lengthComputable = false) =>
        type === "readystatechange" ? new Event(type) : new ProgressEvent(type, { loaded, total, lengthComputable });

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

      const applyProtectedXHRResponseBody = (state, responseBytes) => {
        const mime = state.overrideMimeType || state.responseHeaders["content-type"] || "text/xml";
        const essence = mime.split(";", 1)[0].trim().toLowerCase();
        const charset = /charset\s*=\s*["']?([^;"'\s]+)/i.exec(mime)?.[1];
        let decoder;
        try { decoder = new TextDecoder(state.responseType === "json" ? "utf-8" : charset || "utf-8"); }
        catch (_) { decoder = new TextDecoder(); }
        const text = decoder.decode(responseBytes);
        state.responseText = text;
        state.responseXML = null;
        if (state.responseType === "" || state.responseType === "document") {
          const xml = essence === "text/xml" || essence === "application/xml" || essence.endsWith("+xml");
          const html = essence === "text/html" && state.responseType === "document";
          if (xml || html) {
            const document = new DOMParser().parseFromString(text, html ? "text/html" : "application/xml");
            if (html || document.getElementsByTagName("parsererror").length === 0) state.responseXML = document;
          }
        }
        switch (state.responseType) {
          case "arraybuffer": state.response = responseBytes.buffer; break;
          case "blob": state.response = new Blob([responseBytes], { type: mime.toLowerCase() }); break;
          case "json":
            try { state.response = JSON.parse(text); } catch (_) { state.response = null; }
            break;
          case "document": state.response = state.responseXML; break;
          default: state.response = text;
        }
      };

      // Buffered transport reports a single progress update after completion.
      // It does not provide incremental upload/download progress or streaming.
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
          sending: false,
          generation: 0,
          requestId: null,
          sent: false,
          timeoutTimer: null,
          sendStarted: 0,
          uploadActive: false,
          uploadComplete: false,
          headers: Object.create(null),
          headerValidator: null,
          method: "GET",
          overrideMimeType: null,
          readyState: 0,
          response: null,
          responseHeaders: {},
          responseText: "",
          responseXML: null,
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
          if (nextState === 4) {
            protectedState.sending = false;
            clearTimeout(protectedState.timeoutTimer);
          }
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
              if (!protectedState.active) return getNativeXMLHttpRequestProperty(xhr, "response");
              if (protectedState.responseType !== "" && protectedState.responseType !== "text" && protectedState.readyState !== 4) return null;
              return protectedState.response;
            },
          },
          responseText: {
            configurable: true,
            enumerable: true,
            get() {
              if (!protectedState.active) return getNativeXMLHttpRequestProperty(xhr, "responseText");
              if (!["", "text"].includes(protectedState.responseType)) {
                throw new DOMException("responseText is only available for text responses", "InvalidStateError");
              }
              return protectedState.readyState < 3 ? "" : protectedState.responseText;
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
                if (protectedState.readyState === 3 || protectedState.readyState === 4) {
                  throw new DOMException("responseType cannot be changed after loading starts", "InvalidStateError");
                }
                const type = String(value);
                if (["", "text", "json", "arraybuffer", "blob", "document"].includes(type)) protectedState.responseType = type;
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
              if (!protectedState.active) return getNativeXMLHttpRequestProperty(xhr, "responseXML");
              if (!["", "document"].includes(protectedState.responseType)) {
                throw new DOMException("responseXML is unavailable for this responseType", "InvalidStateError");
              }
              return protectedState.readyState === 4 ? protectedState.responseXML : null;
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
                protectedState.timeout = Number(value) >>> 0;
                scheduleProtectedTimeout();
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

        const cancelProtectedRequest = () => {
          clearTimeout(protectedState.timeoutTimer);
          if (protectedState.sent && protectedState.requestId) {
            Promise.resolve(nativeHandler.postMessage({ kind: "cancel", requestId: protectedState.requestId })).catch(() => {});
          }
          protectedState.sent = false;
        };

        const failProtectedRequest = (type) => {
          cancelProtectedRequest();
          const generation = ++protectedState.generation;
          const current = () => protectedState.active && protectedState.generation === generation;
          protectedState.status = 0;
          protectedState.statusText = "";
          protectedState.response = null;
          protectedState.responseText = "";
          protectedState.responseXML = null;
          protectedState.responseURL = "";
          protectedState.responseHeaders = {};
          changeProtectedReadyState(4);
          if (!current()) return;
          if (protectedState.uploadActive && !protectedState.uploadComplete) {
            protectedState.uploadComplete = true;
            xhr.upload.dispatchEvent(makeXHREvent(type));
            if (!current()) return;
            xhr.upload.dispatchEvent(makeXHREvent("loadend"));
            if (!current()) return;
          }
          xhr.dispatchEvent(makeXHREvent(type));
          if (!current()) return;
          xhr.dispatchEvent(makeXHREvent("loadend"));
          if (type === "abort" && current()) protectedState.readyState = 0;
        };

        const scheduleProtectedTimeout = () => {
          clearTimeout(protectedState.timeoutTimer);
          if (!protectedState.sending || !protectedState.timeout) return;
          const generation = protectedState.generation;
          const remaining = protectedState.timeout - (performance.now() - protectedState.sendStarted);
          protectedState.timeoutTimer = setTimeout(() => {
            if (protectedState.sending && protectedState.generation === generation) failProtectedRequest("timeout");
          }, Math.max(0, remaining));
        };

        xhr.open = (method, url, async = true, user = null, password = null) => {
          const protectedURL = isProtectedEndpoint(url);
          let resolvedURL;
          try { resolvedURL = new URL(url, document.baseURI).toString(); }
          catch (_) { return nativeOpen(method, url, async, user, password); }
          let validator = null;
          if (protectedURL) {
            // Let WebKit perform Web IDL, token and forbidden-method validation
            // without changing the live request or sending browser traffic.
            validator = new OriginalXMLHttpRequest();
            validator.open(method, resolvedURL, async, user, password);
            if (!Boolean(async)) {
              throw new DOMException("Synchronous XMLHttpRequest is not supported for protected endpoints.", "NotSupportedError");
            }
            const parsedURL = new URL(resolvedURL);
            if (user !== null || password !== null || parsedURL.username || parsedURL.password) {
              throw new DOMException("Protected XMLHttpRequest authentication arguments are not supported", "NotSupportedError");
            }
          }

          const savedResponseType = xhr.responseType;
          const savedTimeout = xhr.timeout;
          const savedCredentials = xhr.withCredentials;
          cancelProtectedRequest();
          protectedState.generation += 1;
          protectedState.aborted = false;
          protectedState.sending = false;
          protectedState.active = false;
          protectedState.headers = Object.create(null);
          protectedState.headerValidator = validator;
          const methodString = String(method);
          const normalizedMethod = methodString.toUpperCase();
          protectedState.method = ["DELETE", "GET", "HEAD", "OPTIONS", "POST", "PUT"].includes(normalizedMethod)
            ? normalizedMethod : methodString;
          protectedState.overrideMimeType = null;
          protectedState.readyState = 0;
          protectedState.response = null;
          protectedState.responseHeaders = {};
          protectedState.responseText = "";
          protectedState.responseType = savedResponseType;
          protectedState.responseURL = "";
          protectedState.status = 0;
          protectedState.statusText = "";
          protectedState.timeout = savedTimeout;
          protectedState.url = resolvedURL;
          protectedState.withCredentials = savedCredentials;

          if (!protectedURL) {
            logUnprotectedRequestBypass("xhr", resolvedURL);
            return nativeOpen(method, url, async, user, password);
          }

          protectedState.active = true;
          changeProtectedReadyState(1);
        };

        xhr.setRequestHeader = (name, value) => {
          if (!protectedState.active) {
            nativeSetRequestHeader(name, value);
            return;
          }

          if (protectedState.readyState !== 1 || protectedState.sending) {
            throw new DOMException("Request headers cannot be changed in this state", "InvalidStateError");
          }
          const headerName = String(name);
          const headerValue = String(value);
          protectedState.headerValidator.setRequestHeader(headerName, headerValue);
          const key = headerName.toLowerCase();
          const forbidden = ["accept-charset", "accept-encoding", "access-control-request-headers",
            "access-control-request-method", "connection", "content-length", "cookie", "cookie2",
            "date", "dnt", "expect", "host", "keep-alive", "origin", "permissions-policy", "referer",
            "te", "trailer", "transfer-encoding", "upgrade", "via"];
          if (forbidden.includes(key) || key.startsWith("proxy-") || key.startsWith("sec-")) return;
          if (["x-http-method", "x-http-method-override", "x-method-override"].includes(key) &&
              headerValue.split(",").some(value => ["CONNECT", "TRACE", "TRACK"].includes(value.trim().toUpperCase()))) return;
          const normalizedValue = headerValue.replace(/^[\t ]+|[\t ]+$/g, "");
          protectedState.headers[key] = Object.prototype.hasOwnProperty.call(protectedState.headers, key)
            ? `${protectedState.headers[key]}, ${normalizedValue}` : normalizedValue;
        };

        xhr.getResponseHeader = (name) => {
          if (!protectedState.active) {
            return nativeGetResponseHeader(name);
          }

          if (protectedState.readyState < 2) return null;
          const key = String(name).toLowerCase();
          if (["set-cookie", "set-cookie2"].includes(key)) return null;
          return protectedState.responseHeaders[key] ?? null;
        };

        xhr.getAllResponseHeaders = () => {
          if (!protectedState.active) {
            return nativeGetAllResponseHeaders();
          }

          if (protectedState.readyState < 2) return "";
          return Object.entries(protectedState.responseHeaders)
            .filter(([name]) => !["set-cookie", "set-cookie2"].includes(name))
            .sort(([a], [b]) => a.localeCompare(b))
            .map(([name, value]) => `${name}: ${value}`)
            .map(line => line + "\r\n").join("");
        };

        if (nativeOverrideMimeType) {
          xhr.overrideMimeType = (mimeType) => {
            if (!protectedState.active) {
              nativeOverrideMimeType(mimeType);
              return;
            }

            if (protectedState.readyState === 3 || protectedState.readyState === 4) {
              throw new DOMException("MIME type cannot be changed after loading starts", "InvalidStateError");
            }
            protectedState.overrideMimeType = String(mimeType);
          };
        }

        xhr.abort = () => {
          if (!protectedState.active) { nativeAbort(); return; }
          protectedState.aborted = true;
          if (protectedState.sending || [2, 3].includes(protectedState.readyState)) {
            failProtectedRequest("abort");
          } else {
            cancelProtectedRequest();
            protectedState.generation += 1;
            protectedState.readyState = 0;
            protectedState.status = 0;
            protectedState.statusText = "";
            protectedState.response = null;
            protectedState.responseText = "";
            protectedState.responseXML = null;
            protectedState.responseHeaders = {};
            protectedState.responseURL = "";
          }
        };

        xhr.send = (body = null) => {
          if (!protectedState.active) {
            nativeSend(body);
            return;
          }

          if (protectedState.readyState !== 1 || protectedState.sending) {
            throw new DOMException("XMLHttpRequest is not opened or send is already in progress", "InvalidStateError");
          }
          if (typeof ReadableStream !== "undefined" && body instanceof ReadableStream) {
            throw new TypeError("Streaming protected XMLHttpRequest bodies are not supported");
          }
          protectedState.sending = true;
          protectedState.sendStarted = performance.now();
          scheduleProtectedTimeout();
          const generation = protectedState.generation;
          const isCurrent = () => protectedState.active && protectedState.generation === generation && !protectedState.aborted;
          const requestId = allocateRequestID();
          protectedState.requestId = requestId;
          protectedState.uploadActive = body != null && !["GET", "HEAD"].includes(protectedState.method);
          protectedState.uploadComplete = false;
          xhr.dispatchEvent(makeXHREvent("loadstart"));
          if (!isCurrent()) return;
          if (protectedState.uploadActive) xhr.upload.dispatchEvent(makeXHREvent("loadstart"));
          if (!isCurrent()) return;
          void (async () => {
          try {
            const serializedBody = await serializeBody(["GET", "HEAD"].includes(protectedState.method) ? null : body);
            if (!isCurrent()) return;
            const headers = { ...protectedState.headers };
            if (serializedBody.contentType && !Object.prototype.hasOwnProperty.call(headers, "content-type")) {
              headers["content-type"] = serializedBody.contentType;
            }
            protectedState.sent = true;
            const nativeResponse = await nativeHandler.postMessage({
              requestId,
              url: protectedState.url,
              method: protectedState.method,
              headers,
              bodyBase64: serializedBody.bodyBase64,
              sourcePageURL: window.location.href,
              responseHandling: "response",
              requestSource: "xhr",
            });

            if (!isCurrent()) {
              return;
            }

            protectedState.sent = false;
            if (protectedState.uploadActive) {
              protectedState.uploadComplete = true;
              for (const type of ["progress", "load", "loadend"]) {
                xhr.upload.dispatchEvent(makeXHREvent(type, serializedBody.byteLength, serializedBody.byteLength, true));
                if (!isCurrent()) return;
              }
            }
            protectedState.status = nativeResponse.status;
            protectedState.statusText = nativeResponse.statusText;
            protectedState.responseURL = nativeResponse.url || protectedState.url;
            protectedState.responseHeaders = Object.fromEntries(
              Object.entries(nativeResponse.headers).map(([name, value]) => [name.toLowerCase(), value]),
            );
            changeProtectedReadyState(2);
            if (!isCurrent()) return;
            const bytes = base64ToUint8Array(nativeResponse.bodyBase64);
            applyProtectedXHRResponseBody(protectedState, bytes);
            if (bytes.byteLength) {
              changeProtectedReadyState(3);
              if (!isCurrent()) return;
              xhr.dispatchEvent(makeXHREvent("progress", bytes.byteLength, bytes.byteLength, true));
              if (!isCurrent()) return;
            }
            changeProtectedReadyState(4);
            if (!isCurrent()) return;
            xhr.dispatchEvent(makeXHREvent("load", bytes.byteLength, bytes.byteLength, true));
            if (!isCurrent()) return;
            xhr.dispatchEvent(makeXHREvent("loadend", bytes.byteLength, bytes.byteLength, true));
          } catch (error) {
            if (isCurrent()) failProtectedRequest("error");
          }
          })();
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

      // Reserve the browser default only after ordinary submit listeners run.
      // A task observes final synchronous mutations; microtasks can run between
      // trusted event listeners and are too early for this purpose.
      document.addEventListener("submit", (event) => {
        const form = event.target;
        if (!(form instanceof HTMLFormElement) || !event.cancelable) return;
        const submitter = event.submitter || submitterByForm.get(form) || null;
        let cancelled = event.defaultPrevented;
        let reserved = false;
        let failure = null;
        const preventDefault = event.preventDefault;
        const stopPropagation = event.stopPropagation;
        const stopImmediatePropagation = event.stopImmediatePropagation;
        const reserve = () => {
          if (reserved) return;
          cancelled ||= event.defaultPrevented;
          try {
            if (isNativeHandledForm(form, submitter)) {
              reserved = true;
              preventDefault.call(event);
            }
          } catch (error) {
            failure = error;
            reserved = true;
            preventDefault.call(event);
          }
        };
        event.preventDefault = function () { cancelled = true; return preventDefault.call(this); };
        event.stopPropagation = function () { reserve(); return stopPropagation.call(this); };
        event.stopImmediatePropagation = function () { reserve(); return stopImmediatePropagation.call(this); };
        const returnValue = Object.getOwnPropertyDescriptor(Event.prototype, "returnValue");
        if (returnValue?.set) Object.defineProperty(event, "returnValue", {
          configurable: true,
          get() { return returnValue.get.call(this); },
          set(value) { if (value === false) cancelled = true; returnValue.set.call(this, value); },
        });
        const finish = candidate => { if (candidate === event) reserve(); };
        window.addEventListener("submit", finish);
        setTimeout(() => {
          window.removeEventListener("submit", finish);
          if (cancelled || !reserved) return;
          if (failure) { handleNativeFormError(form, failure); return; }
          try {
            if (isNativeHandledForm(form, submitter)) void proxyFormSubmission(form, submitter);
            else submitFormWithNativeDefault(form, submitter);
          } catch (error) { handleNativeFormError(form, error); }
        }, 0);
      }, true);

      const submitFormWithNativeDefault = (form, submitter) => {
        const attributes = ["action", "method", "enctype", "target"];
        const saved = attributes.map(name => form.getAttribute(name));
        const control = submitter && !submitter.disabled && submitter.name ? document.createElement("input") : null;
        try {
          for (const name of attributes) {
            if (submitter?.hasAttribute(`form${name}`)) form.setAttribute(name, submitter.getAttribute(`form${name}`));
          }
          if (control) { control.type = "hidden"; control.name = submitter.name; control.value = submitter.value; form.append(control); }
          originalFormSubmit.call(form);
        } finally {
          control?.remove();
          attributes.forEach((name, index) => saved[index] === null ? form.removeAttribute(name) : form.setAttribute(name, saved[index]));
        }
      };

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
