// Read assertions still target the original, submitted textarea.
async function fillMarkdown(textarea, value) {
  await textarea.waitFor({ state: 'attached' });
  await textarea.evaluate(element => element.dispatchEvent(new Event('markdown-focus', { cancelable: true })));
  const page = textarea.page();
  await page.waitForFunction(element => element.dataset.markdownSource === 'easymde', await textarea.elementHandle());
  await textarea.evaluate((element, value) => element.closest('.markdown-editor').querySelector('.CodeMirror').CodeMirror.setValue(value), value);
}

async function pressMarkdown(textarea, keys) {
  await textarea.evaluate(element => element.dispatchEvent(new Event('markdown-focus', { cancelable: true })));
  await textarea.page().waitForFunction(element => element.dataset.markdownSource === 'easymde', await textarea.elementHandle());
  await textarea.evaluate(element => element.closest('.markdown-editor').querySelector('.CodeMirror').CodeMirror.focus());
  await textarea.page().keyboard.press(keys);
}

module.exports = { fillMarkdown, pressMarkdown };
