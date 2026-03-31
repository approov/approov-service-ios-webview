import Foundation

/// Generates the JavaScript bridge injected into the page.
///
/// This stays internal to the package, but is split into its own file because
/// it is effectively a separate runtime component from the native Swift code.
package enum ApproovWebViewJavaScriptBridge {
    private static let handlerPlaceholder = "__APPROOV_BRIDGE_HANDLER__"
    private static let protectedEndpointsPlaceholder = "__APPROOV_PROTECTED_ENDPOINTS__"

    package static func scriptSource(
        handlerName: String,
        protectedEndpoints: [ApproovWebViewProtectedEndpoint]
    ) -> String {
        template
            .replacingOccurrences(of: handlerPlaceholder, with: handlerName)
            .replacingOccurrences(
                of: protectedEndpointsPlaceholder,
                with: protectedEndpointsJSON(protectedEndpoints)
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

      // XMLHttpRequest is also wrapped because many WebView apps still use it.
      class ApproovXMLHttpRequest {
        constructor() {
          this.readyState = 0;
          this.status = 0;
          this.statusText = "";
          this.response = null;
          this.responseText = "";
          this.responseType = "";
          this.responseURL = "";
          this.onreadystatechange = null;
          this.onload = null;
          this.onerror = null;
          this.onloadend = null;
          this.onabort = null;
          this._headers = {};
          this._responseHeaders = {};
          this._listeners = {};
          this._fallback = null;
          this._url = "";
          this._method = "GET";
        }

        open(method, url, async = true, user = null, password = null) {
          this._method = (method || "GET").toUpperCase();
          this._url = new URL(url, window.location.href).toString();
          this._headers = {};
          this._responseHeaders = {};
          this._fallback = null;

          if (!isProtectedEndpoint(this._url)) {
            this._fallback = new OriginalXMLHttpRequest();
            this._wireFallback();
            this._fallback.responseType = this.responseType;
            this._fallback.open(method, url, async, user, password);
            return;
          }

          this._changeReadyState(1);
        }

        setRequestHeader(name, value) {
          if (this._fallback) {
            this._fallback.setRequestHeader(name, value);
            return;
          }

          this._headers[name] = value;
        }

        getResponseHeader(name) {
          if (this._fallback) {
            return this._fallback.getResponseHeader(name);
          }

          return this._responseHeaders[name.toLowerCase()] || null;
        }

        getAllResponseHeaders() {
          if (this._fallback) {
            return this._fallback.getAllResponseHeaders();
          }

          return Object.entries(this._responseHeaders)
            .map(([name, value]) => `${name}: ${value}`)
            .join("\r\n");
        }

        addEventListener(type, listener) {
          this._listeners[type] = this._listeners[type] || new Set();
          this._listeners[type].add(listener);
        }

        removeEventListener(type, listener) {
          this._listeners[type]?.delete(listener);
        }

        abort() {
          if (this._fallback) {
            this._fallback.abort();
            return;
          }

          this._dispatch("abort");
          this._dispatch("loadend");
        }

        async send(body = null) {
          if (this._fallback) {
            this._fallback.send(body);
            return;
          }

          try {
            const nativeResponse = await nativeHandler.postMessage({
              url: this._url,
              method: this._method,
              headers: this._headers,
              bodyBase64: await serializeBody(body),
              sourcePageURL: window.location.href,
              responseHandling: "response",
              requestSource: "xhr",
            });

            this.status = nativeResponse.status;
            this.statusText = nativeResponse.statusText;
            this.responseURL = nativeResponse.url || this._url;
            this._responseHeaders = Object.fromEntries(
              Object.entries(nativeResponse.headers).map(([name, value]) => [name.toLowerCase(), value]),
            );

            this._changeReadyState(2);
            this._changeReadyState(3);
            this._applyResponseBody(base64ToUint8Array(nativeResponse.bodyBase64));
            this._changeReadyState(4);
            this._dispatch("load");
            this._dispatch("loadend");
          } catch (error) {
            this._changeReadyState(4);
            this._dispatch("error", error);
            this._dispatch("loadend");
          }
        }

        _applyResponseBody(responseBytes) {
          switch (this.responseType) {
            case "arraybuffer":
              this.response = responseBytes.buffer;
              this.responseText = "";
              break;
            case "blob":
              this.response = new Blob([responseBytes]);
              this.responseText = "";
              break;
            case "json": {
              const textValue = textDecoder.decode(responseBytes);
              this.responseText = textValue;
              this.response = textValue ? JSON.parse(textValue) : null;
              break;
            }
            case "":
            case "text":
            default: {
              const textValue = textDecoder.decode(responseBytes);
              this.responseText = textValue;
              this.response = textValue;
            }
          }
        }

        _changeReadyState(nextState) {
          this.readyState = nextState;
          this._dispatch("readystatechange");
        }

        _dispatch(type, detail = null) {
          const event = new Event(type);
          event.detail = detail;

          const propertyHandler = this[`on${type}`];
          if (typeof propertyHandler === "function") {
            propertyHandler.call(this, event);
          }

          this._listeners[type]?.forEach((listener) => {
            listener.call(this, event);
          });
        }

        _wireFallback() {
          const eventNames = ["readystatechange", "load", "error", "loadend", "abort"];

          eventNames.forEach((eventName) => {
            this._fallback.addEventListener(eventName, (event) => {
              this._syncFromFallback();
              this._dispatch(eventName, event);
            });
          });
        }

        _syncFromFallback() {
          this.readyState = this._fallback.readyState;
          this.status = this._fallback.status;
          this.statusText = this._fallback.statusText;
          this.response = this._fallback.response;
          this.responseType = this._fallback.responseType;
          this.responseURL = this._fallback.responseURL;

          try {
            this.responseText = typeof this._fallback.responseText === "string"
              ? this._fallback.responseText
              : "";
          } catch (_error) {
            this.responseText = "";
          }
        }
      }

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

      window.XMLHttpRequest = ApproovXMLHttpRequest;
      window.__approovBridgeEnabled = true;
      window.__approovBridgeFeatures = {
        fetch: true,
        xhr: true,
        forms: true,
        cookieSync: true,
        simulatedNavigations: true,
      };
    })();
    """#
}
