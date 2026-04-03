---
name: kagi-summarize
description: Summarize web pages and articles using Kagi's Universal Summarizer. Provide a URL and get back a concise summary with the article title. Use when user wants to summarize an article, get the gist of a web page, or simplify complex content.
---

# Kagi URL Summarizer

Use Kagi's Universal Summarizer to get summaries of web pages and articles.

## When to Use

- User provides a URL and asks to summarize it
- User wants to "get the gist" or "TLDR" of an article
- User wants to simplify complex content

## Process

1. **Navigate to Kagi Summarizer**: `https://kagi.com/summarizer`
2. **Fill in the URL** in the input field
3. **Click "Summarize"** button
4. **Wait for results** (typically 5-15 seconds)
5. **Extract title and summary content** using the code below
6. **Return as JSON**

## Output Format

```json
{
  "title": "Article Title",
  "content": "Summary content paragraphs..."
}
```

## Playwright Extraction Code

```javascript
// Wait for summarization to complete (button re-enabled)
await page.waitForFunction(() => {
  var btn = document.querySelector('button[name="Summarize"], [class*="Summarize"]');
  return btn && !btn.disabled;
}, { timeout: 20000 });

// Extract title and content
var result = { title: '', content: '' };
var main = document.querySelector('main');
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
        result.content += text + '\n\n';
      }
    }
    break;
  }
}
result.content = result.content.trim();
JSON.stringify(result);
```

## Notes

- Summarization typically takes 5-15 seconds
- The summarizer supports different modes (Summary Short/Medium/Long, Simplify)
- If summarization fails, Kagi shows an error message
- Always check for error states ("not able to extract the source")
- Copy to Clipboard button is available after summarization
