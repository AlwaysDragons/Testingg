"""Stealth patches on top of playwright-stealth.

playwright-stealth covers the big fingerprint flags (webdriver, chrome, plugins,
permissions, languages, iframe content window). This layer adds the smaller ones
that marketplace detection stacks (Depop + Grailed + Mercari + Vanguard-grade AC
on supplier portals) still probe for after stealth v1:

- navigator.hardwareConcurrency pinned to a realistic 8
- navigator.deviceMemory pinned to 8
- WebGL vendor/renderer spoofed to Intel Iris on Mac
- Canvas noise so fingerprinthash varies run-to-run inside the same account
- toString traps on the patched functions so .toString() returns native code
"""
from __future__ import annotations

from playwright.async_api import BrowserContext, Page

_INIT_SCRIPT = r"""
(() => {
    const define = (obj, name, value) => {
        try {
            Object.defineProperty(obj, name, { get: () => value, configurable: true });
        } catch (_) {}
    };

    define(navigator, 'hardwareConcurrency', 8);
    define(navigator, 'deviceMemory', 8);
    define(navigator, 'maxTouchPoints', 0);

    const vendorMap = { 37445: 'Intel Inc.', 37446: 'Intel Iris OpenGL Engine' };
    const origGetParameter = WebGLRenderingContext.prototype.getParameter;
    WebGLRenderingContext.prototype.getParameter = function (p) {
        if (p in vendorMap) return vendorMap[p];
        return origGetParameter.apply(this, [p]);
    };
    if (window.WebGL2RenderingContext) {
        const origGetParameter2 = WebGL2RenderingContext.prototype.getParameter;
        WebGL2RenderingContext.prototype.getParameter = function (p) {
            if (p in vendorMap) return vendorMap[p];
            return origGetParameter2.apply(this, [p]);
        };
    }

    const origGetContext = HTMLCanvasElement.prototype.getContext;
    HTMLCanvasElement.prototype.getContext = function (type, ...rest) {
        const ctx = origGetContext.call(this, type, ...rest);
        if (type === '2d' && ctx) {
            const origGetImageData = ctx.getImageData;
            ctx.getImageData = function (sx, sy, sw, sh) {
                const img = origGetImageData.call(this, sx, sy, sw, sh);
                for (let i = 0; i < img.data.length; i += 97) {
                    img.data[i] = img.data[i] ^ 1;
                }
                return img;
            };
        }
        return ctx;
    };

    const nativeToString = Function.prototype.toString;
    Function.prototype.toString = function () {
        if (this === HTMLCanvasElement.prototype.getContext) {
            return 'function getContext() { [native code] }';
        }
        if (this === WebGLRenderingContext.prototype.getParameter) {
            return 'function getParameter() { [native code] }';
        }
        return nativeToString.call(this);
    };
})();
"""


async def apply_stealth(context: BrowserContext) -> None:
    """Apply stealth patches to every page the context opens."""
    await context.add_init_script(_INIT_SCRIPT)


async def apply_stealth_page(page: Page) -> None:
    """One-shot stealth on a specific page — use when a context already has pages open."""
    from playwright_stealth import stealth_async  # lazy — avoids pkg_resources import at module load

    await stealth_async(page)
