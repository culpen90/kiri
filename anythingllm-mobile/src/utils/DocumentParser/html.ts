import { Parser } from 'htmlparser2';

const NAMED_ENTITIES: Record<string, string> = {
    amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: ' ',
    mdash: '—', ndash: '–', hellip: '…', copy: '©', reg: '®',
    lsquo: '‘', rsquo: '’', ldquo: '“', rdquo: '”',
};

const HIDDEN_ELEMENTS = new Set(['script', 'style', 'head', 'noscript', 'template']);
const LINE_BREAK_ELEMENTS = new Set([
    'p', 'div', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'li', 'tr', 'blockquote',
    'pre', 'section', 'article', 'header', 'footer', 'table', 'ul', 'ol', 'dd', 'dt',
]);

export function decodeHtmlEntities(input: string): string {
    return input.replace(/&(#x[0-9a-f]+|#\d+|[a-z]+);/gi, (match, entity: string) => {
        const lower = entity.toLowerCase();
        if (lower.startsWith('#x')) return String.fromCodePoint(parseInt(lower.slice(2), 16));
        if (lower.startsWith('#')) return String.fromCodePoint(parseInt(lower.slice(1), 10));
        return NAMED_ENTITIES[lower] ?? match;
    });
}

/**
 * Reduce an HTML document to readable text. Block-level elements become line breaks so the
 * chunker sees paragraph boundaries; everything inside script/style/head is dropped.
 */
export function htmlToText(html: string): string {
    const text: string[] = [];
    let hiddenDepth = 0;

    new Parser({
        onopentagname(name) {
            if (HIDDEN_ELEMENTS.has(name)) hiddenDepth++;
            if (hiddenDepth > 0) return;

            if (name === 'br') text.push('\n');
            if (name === 'td' || name === 'th') text.push('\t');
        },
        onclosetag(name, isImplied) {
            if (HIDDEN_ELEMENTS.has(name)) hiddenDepth--;
            if (hiddenDepth === 0 && !isImplied && LINE_BREAK_ELEMENTS.has(name)) text.push('\n');
        },
        ontext(value) {
            if (hiddenDepth === 0) text.push(value);
        },
    }, { decodeEntities: false }).end(html);

    // One block per line, blank lines dropped: source indentation and closing tags otherwise
    // leave runs of empty lines that add nothing for chunking.
    return decodeHtmlEntities(text.join(''))
        .split('\n')
        .map(line => line.replace(/[ \t ]+/g, ' ').trim())
        .filter(Boolean)
        .join('\n');
}
