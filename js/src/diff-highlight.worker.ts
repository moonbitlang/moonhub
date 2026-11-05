import { createHighlighterCore, type LanguageRegistration } from "shiki/core";
import { createJavaScriptRegexEngine } from "shiki/engine/javascript";
import moonbit from "shiki/langs/moonbit.mjs";
import githubLight from "shiki/themes/github-light.mjs";

const highlighter = createHighlighterCore({ themes: [githubLight], langs: [moonbit], engine: createJavaScriptRegexEngine() });
self.onmessage = async (event: MessageEvent<{ id: number; text: string; lang: string; grammar?: LanguageRegistration[] }>) => {
  const { id, text, lang, grammar } = event.data;
  try {
    const engine = await highlighter;
    if (grammar && !engine.getLoadedLanguages().includes(lang)) await engine.loadLanguage(...grammar);
    const tokens = engine.codeToTokens(text, { lang, theme: "github-light" }).tokens;
    self.postMessage({ id, tokens });
  } catch {
    self.postMessage({ id, tokens: [] });
  }
};
