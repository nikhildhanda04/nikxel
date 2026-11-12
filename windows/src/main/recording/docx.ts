import { Block, Inline, ListItem, parseMarkdown, safeHref } from "./markdown";
import { zip } from "./zip";

/// Markdown -> a minimal, valid Word .docx. On the Mac AppKit wrote .docx
/// from an attributed string; Windows has no such API, so this writes the
/// handful of OOXML parts by hand: headings, paragraphs, bullet/numbered/task
/// lists, bold/italic/inline code, links, code blocks, rules, quotes, tables.

const W_NS = "http://schemas.openxmlformats.org/wordprocessingml/2006/main";
const R_NS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships";
const REL = "http://schemas.openxmlformats.org/officeDocument/2006/relationships";

/// XML-escapes and drops characters XML 1.0 forbids (a stray control char
/// from a transcript would otherwise make Word refuse the whole file).
function x(text: string): string {
  return text
    .replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F￾￿]/g, "")
    .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
}

interface RunStyle { b?: boolean; i?: boolean; code?: boolean; link?: boolean }

class DocWriter {
  private links: string[] = [];
  /// Ordered lists each get their own w:num so numbering restarts per list.
  private orderedNums: number[] = [];   // start value per allocated num, numId = 2 + index

  private run(text: string, st: RunStyle): string {
    // CT_RPr order: rStyle, b, i.
    const style = st.code ? "InlineCode" : st.link ? "Hyperlink" : null;
    const rPr = (style ? `<w:rStyle w:val="${style}"/>` : "") + (st.b ? "<w:b/>" : "") + (st.i ? "<w:i/>" : "");
    const parts = text.split("\t").map(t => `<w:t xml:space="preserve">${x(t)}</w:t>`).join("<w:tab/>");
    return `<w:r>${rPr ? `<w:rPr>${rPr}</w:rPr>` : ""}${parts}</w:r>`;
  }

  runs(inl: Inline[], st: RunStyle = {}): string {
    return inl.map(n => {
      switch (n.t) {
        case "text": return this.run(n.s, st);
        case "code": return this.run(n.s, { ...st, code: true });
        case "b": return this.runs(n.c, { ...st, b: true });
        case "i": return this.runs(n.c, { ...st, i: true });
        case "link": {
          const href = safeHref(n.href);
          if (!href || st.link) return this.runs(n.c, st);
          this.links.push(href);
          return `<w:hyperlink r:id="rIdLink${this.links.length}">${this.runs(n.c, { ...st, link: true })}</w:hyperlink>`;
        }
      }
    }).join("");
  }

  private para(pPr: string, body: string): string {
    return `<w:p>${pPr ? `<w:pPr>${pPr}</w:pPr>` : ""}${body}</w:p>`;
  }

  private list(items: ListItem[]): string {
    let orderedNum = 0;
    return items.map(it => {
      let numId = 1;
      if (it.ordered) {
        if (!orderedNum) { this.orderedNums.push(it.num || 1); orderedNum = 1 + this.orderedNums.length; }
        numId = orderedNum;
      }
      const box = it.check === null ? "" : this.run(it.check ? "☑ " : "☐ ", {});
      const pPr = `<w:pStyle w:val="ListParagraph"/><w:numPr><w:ilvl w:val="${it.level}"/><w:numId w:val="${numId}"/></w:numPr>`;
      return this.para(pPr, box + this.runs(it.inl));
    }).join("");
  }

  private table(header: Inline[][], rows: Inline[][][]): string {
    const cols = Math.max(header.length, ...rows.map(r => r.length), 1);
    const width = Math.floor(10080 / cols);   // text width between 0.75" margins, in twips
    const cell = (inl: Inline[] | undefined, bold: boolean) =>
      `<w:tc><w:tcPr><w:tcW w:w="${width}" w:type="dxa"/></w:tcPr>${this.para("", this.runs(inl ?? [], bold ? { b: true } : {}))}</w:tc>`;
    const row = (r: Inline[][], bold: boolean) => {
      let out = "<w:tr>";
      for (let c = 0; c < cols; c++) out += cell(r[c], bold);
      return out + "</w:tr>";
    };
    return `<w:tbl><w:tblPr><w:tblStyle w:val="TableGrid"/><w:tblW w:w="0" w:type="auto"/></w:tblPr>` +
      `<w:tblGrid>${`<w:gridCol w:w="${width}"/>`.repeat(cols)}</w:tblGrid>` +
      row(header, true) + rows.map(r => row(r, false)).join("") + "</w:tbl>";
  }

  body(blocks: Block[]): string {
    const out: string[] = [];
    for (const b of blocks) {
      switch (b.t) {
        case "h": out.push(this.para(`<w:pStyle w:val="Heading${b.level}"/>`, this.runs(b.inl))); break;
        case "p": out.push(this.para("", this.runs(b.inl))); break;
        case "quote": out.push(this.para(`<w:pStyle w:val="Quote"/>`, this.runs(b.inl))); break;
        case "hr":
          out.push(this.para(`<w:pBdr><w:bottom w:val="single" w:sz="6" w:space="1" w:color="CCCCCC"/></w:pBdr>`, ""));
          break;
        case "code":
          for (const line of b.text.split("\n")) out.push(this.para(`<w:pStyle w:val="Code"/>`, line ? this.run(line, {}) : ""));
          break;
        case "list": out.push(this.list(b.items)); break;
        case "table": out.push(this.table(b.header, b.rows)); break;
      }
    }
    // Word wants the body to end on a paragraph, not a table.
    out.push("<w:p/>");
    return out.join("\n");
  }

  document(blocks: Block[]): string {
    const body = this.body(blocks);
    return `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="${W_NS}" xmlns:r="${R_NS}"><w:body>
${body}
<w:sectPr><w:pgSz w:w="12240" w:h="15840"/><w:pgMar w:top="1080" w:right="1080" w:bottom="1080" w:left="1080" w:header="720" w:footer="720" w:gutter="0"/></w:sectPr>
</w:body></w:document>`;
  }

  documentRels(): string {
    const links = this.links.map((href, i) =>
      `<Relationship Id="rIdLink${i + 1}" Type="${REL}/hyperlink" Target="${x(href)}" TargetMode="External"/>`).join("");
    return `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rIdStyles" Type="${REL}/styles" Target="styles.xml"/><Relationship Id="rIdNumbering" Type="${REL}/numbering" Target="numbering.xml"/>${links}</Relationships>`;
  }

  numbering(): string {
    const bullets = ["•", "◦", "▪", "•"];
    const lvl = (i: number, fmt: string, text: string) =>
      `<w:lvl w:ilvl="${i}"><w:start w:val="1"/><w:numFmt w:val="${fmt}"/><w:lvlText w:val="${text}"/><w:lvlJc w:val="left"/>` +
      `<w:pPr><w:ind w:left="${720 * (i + 1)}" w:hanging="360"/></w:pPr></w:lvl>`;
    const decimalFmts = ["decimal", "lowerLetter", "lowerRoman", "decimal"];
    let abstract = `<w:abstractNum w:abstractNumId="0"><w:multiLevelType w:val="hybridMultilevel"/>`;
    for (let i = 0; i < 4; i++) abstract += lvl(i, "bullet", bullets[i]);
    abstract += `</w:abstractNum><w:abstractNum w:abstractNumId="1"><w:multiLevelType w:val="hybridMultilevel"/>`;
    for (let i = 0; i < 4; i++) abstract += lvl(i, decimalFmts[i], `%${i + 1}.`);
    abstract += `</w:abstractNum>`;
    let nums = `<w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num>`;
    this.orderedNums.forEach((start, i) => {
      nums += `<w:num w:numId="${i + 2}"><w:abstractNumId w:val="1"/><w:lvlOverride w:ilvl="0"><w:startOverride w:val="${start}"/></w:lvlOverride></w:num>`;
    });
    return `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:numbering xmlns:w="${W_NS}">${abstract}${nums}</w:numbering>`;
  }
}

function headingStyle(level: number): string {
  const sizes = [40, 30, 25, 24, 22, 22];   // half-points: 20pt, 15pt, 12.5pt, as in the PDF
  return `<w:style w:type="paragraph" w:styleId="Heading${level}"><w:name w:val="heading ${level}"/><w:basedOn w:val="Normal"/><w:next w:val="Normal"/><w:uiPriority w:val="9"/><w:qFormat/>` +
    `<w:pPr><w:keepNext/><w:spacing w:before="${level <= 2 ? 360 : 240}" w:after="120"/><w:outlineLvl w:val="${level - 1}"/></w:pPr>` +
    `<w:rPr><w:b/><w:sz w:val="${sizes[level - 1]}"/></w:rPr></w:style>`;
}

const STYLES = `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:styles xmlns:w="${W_NS}">
<w:docDefaults><w:rPrDefault><w:rPr><w:rFonts w:ascii="Calibri" w:hAnsi="Calibri" w:eastAsia="Calibri" w:cs="Calibri"/><w:sz w:val="22"/><w:szCs w:val="22"/><w:lang w:val="en-US"/></w:rPr></w:rPrDefault>
<w:pPrDefault><w:pPr><w:spacing w:after="120" w:line="276" w:lineRule="auto"/></w:pPr></w:pPrDefault></w:docDefaults>
<w:style w:type="paragraph" w:default="1" w:styleId="Normal"><w:name w:val="Normal"/><w:qFormat/></w:style>
${[1, 2, 3, 4, 5, 6].map(headingStyle).join("\n")}
<w:style w:type="paragraph" w:styleId="ListParagraph"><w:name w:val="List Paragraph"/><w:basedOn w:val="Normal"/><w:uiPriority w:val="34"/><w:qFormat/><w:pPr><w:spacing w:after="40"/><w:ind w:left="720"/><w:contextualSpacing/></w:pPr></w:style>
<w:style w:type="paragraph" w:styleId="Code"><w:name w:val="Code"/><w:basedOn w:val="Normal"/><w:qFormat/><w:pPr><w:shd w:val="clear" w:color="auto" w:fill="F4F4F4"/><w:spacing w:after="0" w:line="240" w:lineRule="auto"/></w:pPr><w:rPr><w:rFonts w:ascii="Consolas" w:hAnsi="Consolas" w:cs="Consolas"/><w:sz w:val="20"/></w:rPr></w:style>
<w:style w:type="paragraph" w:styleId="Quote"><w:name w:val="Quote"/><w:basedOn w:val="Normal"/><w:qFormat/><w:pPr><w:pBdr><w:left w:val="single" w:sz="18" w:space="8" w:color="CCCCCC"/></w:pBdr><w:ind w:left="240"/></w:pPr><w:rPr><w:color w:val="444444"/></w:rPr></w:style>
<w:style w:type="character" w:default="1" w:styleId="DefaultParagraphFont"><w:name w:val="Default Paragraph Font"/><w:uiPriority w:val="1"/><w:semiHidden/><w:unhideWhenUsed/></w:style>
<w:style w:type="character" w:styleId="InlineCode"><w:name w:val="Inline Code"/><w:basedOn w:val="DefaultParagraphFont"/><w:rPr><w:rFonts w:ascii="Consolas" w:hAnsi="Consolas" w:cs="Consolas"/><w:sz w:val="20"/><w:shd w:val="clear" w:color="auto" w:fill="F4F4F4"/></w:rPr></w:style>
<w:style w:type="character" w:styleId="Hyperlink"><w:name w:val="Hyperlink"/><w:basedOn w:val="DefaultParagraphFont"/><w:uiPriority w:val="99"/><w:unhideWhenUsed/><w:rPr><w:color w:val="0563C1"/><w:u w:val="single"/></w:rPr></w:style>
<w:style w:type="table" w:default="1" w:styleId="TableNormal"><w:name w:val="Normal Table"/><w:uiPriority w:val="99"/><w:semiHidden/><w:unhideWhenUsed/><w:tblPr><w:tblInd w:w="0" w:type="dxa"/><w:tblCellMar><w:top w:w="0" w:type="dxa"/><w:left w:w="108" w:type="dxa"/><w:bottom w:w="0" w:type="dxa"/><w:right w:w="108" w:type="dxa"/></w:tblCellMar></w:tblPr></w:style>
<w:style w:type="table" w:styleId="TableGrid"><w:name w:val="Table Grid"/><w:basedOn w:val="TableNormal"/><w:uiPriority w:val="39"/><w:pPr><w:spacing w:after="0" w:line="240" w:lineRule="auto"/></w:pPr><w:tblPr><w:tblBorders><w:top w:val="single" w:sz="4" w:space="0" w:color="BBBBBB"/><w:left w:val="single" w:sz="4" w:space="0" w:color="BBBBBB"/><w:bottom w:val="single" w:sz="4" w:space="0" w:color="BBBBBB"/><w:right w:val="single" w:sz="4" w:space="0" w:color="BBBBBB"/><w:insideH w:val="single" w:sz="4" w:space="0" w:color="BBBBBB"/><w:insideV w:val="single" w:sz="4" w:space="0" w:color="BBBBBB"/></w:tblBorders></w:tblPr></w:style>
</w:styles>`;

const CONTENT_TYPES = `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/><Override PartName="/word/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"/><Override PartName="/word/numbering.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"/></Types>`;

const ROOT_RELS = `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="${REL}/officeDocument" Target="word/document.xml"/></Relationships>`;

/// The .docx bytes for `markdown`.
export function markdownToDocx(markdown: string): Buffer {
  const w = new DocWriter();
  // document() must run first: it collects the links and ordered lists the
  // rels and numbering parts describe.
  const document = w.document(parseMarkdown(markdown));
  return zip([
    { name: "[Content_Types].xml", data: CONTENT_TYPES },
    { name: "_rels/.rels", data: ROOT_RELS },
    { name: "word/document.xml", data: document },
    { name: "word/_rels/document.xml.rels", data: w.documentRels() },
    { name: "word/styles.xml", data: STYLES },
    { name: "word/numbering.xml", data: w.numbering() },
  ]);
}
