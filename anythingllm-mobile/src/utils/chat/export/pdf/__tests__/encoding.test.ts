import { stripHtml } from '../encoding';

test('extracts text from HTML with quoted delimiters and comments', () => {
  const html = '<p title="one > zero">Hello<!-- a > b --> <em>world</em> &amp; friends.</p>';
  expect(stripHtml(html)).toBe('Hello world & friends.');
});

test('preserves angle brackets in text and decodes the supported entities once', () => {
  const html = '<div>5 < 7, &lt;code&gt;, &quot;hello&quot;, &#39;today&#39;, and &amp;lt;/code&amp;gt;.</div>';
  expect(stripHtml(html)).toBe('5 < 7, <code>, "hello", \'today\', and &lt;/code&gt;.');
});
