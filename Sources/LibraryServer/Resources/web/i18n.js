// SPDX-License-Identifier: MIT
// G55: Web の UI 言語。キーは日本語の原文。英語の辞書は i18n-en.js。
import { EN } from './i18n-en.js';

let table = EN;

export function detectLang(navigatorLanguage, search) {
  const q = new URLSearchParams(search || '').get('lang');
  if (q === 'ja' || q === 'en') return q;
  return String(navigatorLanguage || '').toLowerCase().startsWith('ja') ? 'ja' : 'en';
}

export let LANG = detectLang(globalThis.navigator?.language, globalThis.location?.search);

function fill(s, params) {
  return s.replace(/\{(\w+)\}/g, (m, k) => (k in params ? String(params[k]) : m));
}

export function t(ja, params = {}) {
  let s = ja;
  if (LANG === 'en' && Object.prototype.hasOwnProperty.call(table, ja)) {
    const e = table[ja];
    s = typeof e === 'string' ? e : (params.count === 1 ? e.one : e.other);
  }
  return fill(s, params);
}

export function applyI18n(root = document) {
  for (const el of root.querySelectorAll('[data-i18n]')) el.textContent = t(el.getAttribute('data-i18n'));
  for (const attr of ['title', 'aria-label', 'placeholder']) {
    for (const el of root.querySelectorAll(`[data-i18n-${attr}]`)) el.setAttribute(attr, t(el.getAttribute(`data-i18n-${attr}`)));
  }
  if (root.documentElement) root.documentElement.lang = LANG;
}

// Tests only.
export function __setLangForTesting(l) { LANG = l; }
export function __setTableForTesting(tb) { table = tb; }
