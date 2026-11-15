import { htmlToText } from '../html';

test('extracts readable blocks, table cells, and escaped text', () => {
    const html = `<!DOCTYPE html><html>
        <head><title>Document metadata</title></head>
        <body>
            <h1 data-note="3 > 2">A &amp; B</h1>
            <p>First line<br />second line with &lt;code&gt;.</p>
            <table><tr><th>Left</th><td>Right</td></tr></table>
        </body>
    </html>`;

    expect(htmlToText(html)).toBe('A & B\nFirst line\nsecond line with <code>.\nLeft Right');
});

test('drops comments and hidden element contents, including nested templates', () => {
    const html = `<p>Visible<!-- editor note --> text</p>
        <script>const value = "a < b";</script>
        <style>p { color: red; }</style>
        <template>
            <p>Outer template</p>
            <template><p>Nested template</p></template>
            <p>Still within the outer template</p>
        </template>
        <noscript><p>Fallback text</p></noscript>
        <p>More visible text</p>`;

    expect(htmlToText(html)).toBe('Visible text\nMore visible text');
});
