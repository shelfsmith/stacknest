// SPDX-License-Identifier: MIT
// G55 Task 7: i18n.js の骨組み（detectLang / t / applyI18n）の純関数テスト。
import { test } from 'node:test';
import assert from 'node:assert/strict';

// i18n.js は browser globals を起動時に読むので、読み込み前に最小の偽物を置く。
// 注: Node（v21+）は globalThis.navigator を getter のみで既に持つため、直接代入は
// TypeError になる。defineProperty で上書きする。
Object.defineProperty(globalThis, 'navigator', { value: { language: 'en-US' }, configurable: true });
globalThis.location = { search: '' };
const { detectLang, t, __setLangForTesting, __setTableForTesting } = await import('../Sources/LibraryServer/Resources/web/i18n.js');

test('detectLang: ?lang が最優先、ja* は ja、他は en', () => {
  assert.equal(detectLang('ja-JP', ''), 'ja');
  assert.equal(detectLang('en-US', ''), 'en');
  assert.equal(detectLang('fr', ''), 'en');
  assert.equal(detectLang('ja', '?lang=en'), 'en');
  assert.equal(detectLang('en', '?x=1&lang=ja'), 'ja');
});

test('t: ja はキー、en は辞書、無ければキー', () => {
  __setTableForTesting({ '閉じる': 'Close', '{n} 冊': { one: '{n} book', other: '{n} books' }, '「{title}」を開く': 'Open “{title}”' });
  __setLangForTesting('ja');
  assert.equal(t('閉じる'), '閉じる');
  assert.equal(t('「{title}」を開く', { title: 'A' }), '「A」を開く');
  __setLangForTesting('en');
  assert.equal(t('閉じる'), 'Close');
  assert.equal(t('未登録'), '未登録');
  assert.equal(t('「{title}」を開く', { title: 'A' }), 'Open “A”');
  assert.equal(t('{n} 冊', { n: 1, count: 1 }), '1 book');
  assert.equal(t('{n} 冊', { n: 3, count: 3 }), '3 books');
});
