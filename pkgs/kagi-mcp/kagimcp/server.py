import asyncio
import json
import os
import time
from urllib.parse import quote_plus

from fastmcp import FastMCP
from playwright.async_api import async_playwright
from playwright_stealth import Stealth

mcp = FastMCP("kagi")

_BROWSER_TTL = int(os.environ.get("KAGI_BROWSER_TTL", "30"))

_stealth = Stealth()

_browser = None
_playwright = None
_context = None
_last_used = 0.0
_shutdown_task = None


async def _shutdown_browser():
    global _browser, _playwright, _context, _shutdown_task
    await asyncio.sleep(_BROWSER_TTL)
    if _browser and time.monotonic() - _last_used >= _BROWSER_TTL:
        await _browser.close()
        await _playwright.stop()
        _browser = None
        _playwright = None
        _context = None
    _shutdown_task = None


def _schedule_shutdown():
    global _shutdown_task
    if _shutdown_task and not _shutdown_task.done():
        _shutdown_task.cancel()
    _shutdown_task = asyncio.ensure_future(_shutdown_browser())


def _auth_url(path: str) -> str:
    token = os.environ.get("KAGI_AUTH_TOKEN", "")
    if token:
        return f"https://kagi.com{path}?token={token}"
    return f"https://kagi.com{path}"


async def _get_browser():
    global _browser, _playwright, _context, _last_used
    if _browser is None or not _browser.is_connected():
        _playwright = await async_playwright().start()
        _browser = await _playwright.chromium.launch(headless=True)
        _context = await _browser.new_context()
        await _stealth.apply_stealth_async(_context)
    _last_used = time.monotonic()
    _schedule_shutdown()
    return _browser


async def _get_page():
    browser = await _get_browser()
    return await _context.new_page()


async def _wait_for_response(page):
    await page.wait_for_timeout(1000)
    await page.wait_for_load_state("networkidle")


async def _wait_for_stable(page, selector_fn: str, interval: int = 500, stable_after: int = 2, timeout: int = 30000) -> str:
    deadline = time.monotonic() + timeout / 1000
    prev = ""
    stable_count = 0
    while time.monotonic() < deadline:
        current = await page.evaluate(selector_fn)
        if current and current == prev:
            stable_count += 1
            if stable_count >= stable_after:
                return current
        else:
            stable_count = 0
        prev = current
        await page.wait_for_timeout(interval)
    return prev


async def _search(query: str) -> str:
    page = await _get_page()
    try:
        url = _auth_url("/search") + f"&q={quote_plus(query)}"
        await page.goto(url)
        await page.wait_for_load_state("networkidle")
        await page.wait_for_timeout(3000)

        result = await page.evaluate("""() => {
            var results = [];
            var seen = new Set();
            var allLinks = document.querySelectorAll('[class*="__sri_title_link"][href]');
            for (var i = 0; i < allLinks.length; i++) {
                var a = allLinks[i];
                var href = a.href;
                if (!href || seen.has(href) || href.indexOf('kagi.com') > -1 ||
                    href.indexOf('youtube.com') > -1 || href.indexOf('web.archive.org') > -1) {
                    continue;
                }
                seen.add(href);
                var title = a.textContent.trim();
                var el = a.closest('[class*="result"]');
                if (!el || !title || title.length < 3) continue;
                var dateEl = el.querySelector('[class*="__sri-time"]');
                var date = dateEl ? dateEl.textContent.trim() : '';
                var paywallEl = el.querySelector('[class*="paywall-icon"]');
                var paywall = paywallEl ? true : false;
                var descEl = el.querySelector('[class*="__sri-desc"] > div');
                var snippet = '';
                if (descEl) {
                    for (var j = 0; j < descEl.childNodes.length; j++) {
                        if (descEl.childNodes[j].nodeType === Node.TEXT_NODE) {
                            snippet += descEl.childNodes[j].textContent;
                        }
                    }
                    snippet = snippet.trim();
                }
                results.push({title: title, url: href, snippet: snippet, date: date, paywall: paywall});
            }
            var qaBtn = document.querySelector('[class*="quick_answer_trigger"]');
            if (qaBtn) qaBtn.click();
            return {results: results, hasQuickAnswer: !!qaBtn};
        }""")

        quick_answer = ""
        if result.get("hasQuickAnswer"):
            await page.wait_for_timeout(1500)
            quick_answer = await page.evaluate("""() => {
                var qaContainer = document.querySelector('[class*="qa-container"]');
                if (!qaContainer) return '';
                return qaContainer.textContent
                    .replace(/Quick Answer|Show More|Show less|References|\\s{2,}/g, ' ')
                    .replace(/45%|35%|20%.*$/gm, '')
                    .trim();
            }""")

        return json.dumps({"quickAnswer": quick_answer, "results": result["results"]}, indent=2)
    finally:
        await page.close()


async def _summarize(url: str) -> str:
    page = await _get_page()
    try:
        await page.goto(_auth_url("/summarizer"), wait_until="domcontentloaded")
        await page.wait_for_load_state("networkidle")
        await page.wait_for_timeout(1000)

        await page.fill('textarea[name="summary_input"]', url)
        await page.click('button[type="submit"]:has-text("Summarize")')

        await _wait_for_stable(
            page,
            """() => {
                var main = document.querySelector('main');
                if (!main) return '';
                var children = main.children;
                for (var i = 0; i < children.length; i++) {
                    if (children[i].textContent.includes('Title:')) {
                        return children[i].textContent.substring(0, 500);
                    }
                }
                return '';
            }""",
        )

        result = await page.evaluate("""() => {
            var result = {title: '', content: ''};
            var main = document.querySelector('main');
            if (!main) return result;
            var children = main.children;
            for (var i = 0; i < children.length; i++) {
                var el = children[i];
                if (el.textContent.includes('Title:')) {
                    var paras = el.querySelectorAll('p');
                    for (var j = 0; j < paras.length; j++) {
                        var text = paras[j].textContent.trim();
                        if (text.startsWith('Title:')) {
                            result.title = text.replace('Title:', '').trim();
                        } else if (text && !text.startsWith('Please') && !text.startsWith('Copy to')) {
                            result.content += text + '\\n\\n';
                        }
                    }
                    break;
                }
            }
            result.content = result.content.trim();
            return result;
        }""")

        return json.dumps(result, indent=2)
    finally:
        await page.close()


async def _ask(prompt: str, model: str = "") -> str:
    page = await _get_page()
    try:
        await page.goto(_auth_url("/assistant"), wait_until="domcontentloaded")
        await page.wait_for_load_state("networkidle")
        await page.wait_for_timeout(1000)

        new_btn = await page.query_selector('button:has-text("+")')
        if new_btn:
            await new_btn.click()
            await page.wait_for_timeout(1000)

        if model:
            await page.click('button#profile-select')
            await page.wait_for_timeout(500)
            await page.click(f'li:has-text("{model}"), [role="option"]:has-text("{model}")')
            await page.wait_for_timeout(500)

        await page.fill('#promptBox', prompt)
        await page.keyboard.press('Enter')

        await _wait_for_stable(
            page,
            """() => {
                var bubbles = document.querySelectorAll('[class*="chat_bubble"]');
                if (bubbles.length < 2) return '';
                var last = bubbles[bubbles.length - 1];
                var contentEl = last.querySelector('[class*="content"]');
                return contentEl ? contentEl.textContent.trim() : '';
            }""",
        )

        result = await page.evaluate("""() => {
            var bubbles = document.querySelectorAll('[class*="chat_bubble"]');
            if (bubbles.length < 2) return {response: '', model: ''};
            var last = bubbles[bubbles.length - 1];
            var contentEl = last.querySelector('[class*="content"]');
            var response = contentEl ? contentEl.textContent.trim() : '';
            var modelEl = last.querySelector('[class*="model"]');
            var modelName = modelEl ? modelEl.textContent.trim() : '';
            return {response: response, model: modelName};
        }""")

        return json.dumps(result, indent=2)
    finally:
        await page.close()


async def _fastgpt(query: str) -> str:
    page = await _get_page()
    try:
        await page.goto(_auth_url("/fastgpt"), wait_until="domcontentloaded")
        await page.wait_for_load_state("networkidle")
        await page.wait_for_timeout(1000)

        await page.fill('#query', query)
        await page.click('button[type=submit]')

        await _wait_for_response(page)

        result = await page.evaluate("""() => {
            var el = document.querySelector('[class*="text_content"]');
            return {response: el ? el.textContent.trim() : ''};
        }""")

        return json.dumps(result, indent=2)
    finally:
        await page.close()


@mcp.tool()
async def search(query: str) -> str:
    """Search the web using Kagi. Returns JSON with quickAnswer and results list."""
    return await _search(query)


@mcp.tool()
async def summarize(url: str) -> str:
    """Summarize a web page using Kagi's Universal Summarizer. Returns JSON with title and content."""
    return await _summarize(url)


@mcp.tool()
async def ask(prompt: str, model: str = "") -> str:
    """Ask Kagi Assistant a question. Returns JSON with response and model. Optionally specify model name (e.g. 'Quick')."""
    return await _ask(prompt, model)


@mcp.tool()
async def fastgpt(query: str) -> str:
    """Get a fast single-answer response from Kagi FastGPT. Best for simple factual questions. Returns JSON with response."""
    return await _fastgpt(query)


def main():
    mcp.run()