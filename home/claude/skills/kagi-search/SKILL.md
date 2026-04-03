---
name: kagi-search
description: Search the web using Kagi search engine. Returns results as JSON including quick answer, snippets, dates, and source URLs. Use when user asks to search the web or look something up.
---

# Kagi Web Search

Use this skill to search the web using Kagi. Returns structured JSON with search results, quick answer, and metadata.

## When to Use

- User asks to "search the web", "look up", "find information about", or "google something"
- User wants to get current information from the internet
- Any web search query

## Process

1. **Navigate to Kagi** with the user's query: `https://kagi.com/search?q={encoded_query}`
2. **Wait for results** to load (Kagi loads results dynamically) - wait ~3 seconds
3. **Extract search results** FIRST (before clicking Quick Answer - see code below)
4. **Click Quick Answer button** to expand the quick answer summary
5. **Return as JSON** in the format shown below

```json
{
  "quickAnswer": "Summary from Kagi's quick answer feature (if available)",
  "results": [
    {
      "title": "Page Title",
      "url": "https://example.com/page",
      "snippet": "Brief description of the page content...",
      "date": "Dec 1, 2025",
      "paywall": false
    }
  ]
}
```

## Kagi URL Format

```
https://kagi.com/search?token={KAGI_TOKEN}&q={encoded_query}
```

The token should be stored in the session or passed by the user. If no token is provided, use `https://kagi.com/search?q={encoded_query}` (may prompt for login).

## Example Search

Navigate to: `https://kagi.com/search?q=what+is+love`

## Playwright Extraction Code

```javascript
// Extract results - run BEFORE clicking Quick Answer to avoid polluting result snippets
var results = [];
var seen = new Set();
var allLinks = document.querySelectorAll('[class*="__sri_title_link"][href]');
for (var i = 0; i < allLinks.length; i++) {
  var a = allLinks[i];
  var href = a.href;
  // Skip if already seen, internal Kagi links, YouTube, Spotify, web.archive.org
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
  
  // Get snippet from __sri-desc > div direct text nodes only
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
  
  results.push({ title: title, url: href, snippet: snippet, date: date, paywall: paywall });
}

// Click Quick Answer button AFTER extracting results
var qaBtn = document.querySelector('[class*="quick_answer_trigger"]');
if (qaBtn) {
  qaBtn.click();
  await new Promise(r => setTimeout(r, 1500));
}

var qaContainer = document.querySelector('[class*="qa-container"]');
var quickAnswer = qaContainer ? qaContainer.textContent
  .replace(/Quick Answer|Show More|Show less|References|\s{2,}/g, ' ')
  .replace(/45%|35%|20%.*$/gm, '')
  .trim() : '';

return JSON.stringify({ quickAnswer, results }, null, 2);
```

## Notes

- **ALWAYS extract results BEFORE clicking Quick Answer** - the QA content pollutes result snippets
- Kagi loads search results dynamically via JavaScript - curl/plain HTTP won't work
- Always use Playwright browser to search Kagi
- Filter out: internal Kagi links, YouTube, Spotify, web.archive.org duplicates, and fragment-only links (#:~:text=)
- Skip titles shorter than 3 characters (usually superscript reference numbers like "1", "2", "3")
- Quick answer is collapsed by default - click the button AFTER extracting results
- Results include a mix of articles, Wikipedia entries, videos, and other sources
- The `paywall` field indicates if the source has a paywall icon (likely requires subscription)
- Use `__sri_title_link[href]` to find result links (not generic a[href] selectors)
- Use `__sri-time` class for dates, `__sri-desc > div` with text nodes for clean snippets
- Use `document.querySelectorAll('[class*="result"] a[href]')` to find result links
