"""Independent hOCR extractor for the D02 comparison lane.

Reads an hOCR file with lxml's HTML parser (libxml2) and emits the
flat, document-order records the Dart parser is diffed against, under
the contract `doc/hocr.md` fixes: role classification by class token,
Tesseract line-role classes, transparent containers, the title grammar
with the comma rule, consumed properties, verbatim data properties, text
with `del` excluded, and the page frame rule. It shares no code with
the Dart implementation. It is an extractor, not a validator: hOCR has
no schema and this module does not pretend to be one.
"""

import re
from lxml import html as lxml_html

LINE_ROLE_TOKENS = {"ocr_header", "ocr_caption", "ocr_textfloat"}
METADATA_NAMES = ("ocr-system", "ocr-capabilities", "ocr-number-of-pages", "ocr-langs", "ocr-scripts")
NAME_RE = re.compile(r"[a-z][a-z0-9_]*")
DECIMAL_RE = re.compile(r"-?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)")


class HocrExtractError(Exception):
    """The document violates the fixed contract; the extractor stops."""


def _tokens(value):
    return value.split() if value else []


def _text_of(element, out, state):
    if element.text:
        out.append(element.text)
    for child in element:
        if not isinstance(child.tag, str):
            if child.tail:
                out.append(child.tail)
            continue
        tag = child.tag.lower()
        if tag == "del":
            state["alternatives"] = True
        elif tag in ("script", "style"):
            pass
        else:
            if tag == "ins":
                state["alternatives"] = True
            _text_of(child, out, state)
        if child.tail:
            out.append(child.tail)


def text_of(element):
    """The element's text under the contract: descendant character data in
    document order, `del`/`script`/`style` subtrees excluded, plus whether
    `ins`/`del` alternatives were present."""
    out, state = [], {"alternatives": False}
    _text_of(element, out, state)
    return "".join(out), state["alternatives"]


def _comma_starts_property(title, index):
    i = index
    while i < len(title) and title[i] in " \t\r\n":
        i += 1
    match = NAME_RE.match(title, i)
    if not match:
        return False
    end = match.end()
    return end < len(title) and title[end] in " \t\r\n"


def split_properties(title):
    segments, start, in_quote = [], 0, False
    for i, ch in enumerate(title):
        if ch == '"':
            in_quote = not in_quote
        elif ch == ";" and not in_quote:
            segments.append(title[start:i])
            start = i + 1
        elif ch == "," and not in_quote and _comma_starts_property(title, i + 1):
            segments.append(title[start:i])
            start = i + 1
    if in_quote:
        raise HocrExtractError("unterminated quote in title")
    segments.append(title[start:])
    return segments


def tokenize(segment):
    tokens, i = [], 0
    while i < len(segment):
        ch = segment[i]
        if ch in " \t\r\n":
            i += 1
            continue
        if ch == '"':
            close = segment.find('"', i + 1)
            if close < 0:
                raise HocrExtractError("unterminated quote in title")
            tokens.append(segment[i + 1 : close])
            i = close + 1
            continue
        start = i
        while i < len(segment) and segment[i] not in " \t\r\n":
            i += 1
        tokens.append(segment[start:i])
    return tokens


def parse_title(title):
    result, seen = [], set()
    for segment in split_properties(title or ""):
        tokens = tokenize(segment)
        if not tokens:
            continue
        name = tokens[0]
        if not NAME_RE.fullmatch(name):
            raise HocrExtractError(f"bad property name {name!r}")
        if name in seen:
            raise HocrExtractError(f"duplicate property {name!r}")
        seen.add(name)
        result.append((name, tokens[1:]))
    return result


def _uint(token):
    if not token.isdigit() or len(token) > 10 or int(token) > 0x7FFFFFFF:
        raise HocrExtractError(f"not a uint: {token!r}")
    return int(token)


def _decimal(token):
    if not DECIMAL_RE.fullmatch(token) or len(token) > 64:
        raise HocrExtractError(f"not a decimal: {token!r}")
    return float(token)


def _bbox(tokens):
    if len(tokens) != 4:
        raise HocrExtractError("bbox arity")
    x0, y0, x1, y1 = (_uint(t) for t in tokens)
    if x1 < x0 or y1 < y0:
        raise HocrExtractError("inverted bbox")
    return [x0, y0, x1, y1]


def classify(element):
    cls = element.get("class")
    if cls is None:
        return None
    role = None
    token_used = None
    for token in _tokens(cls):
        if not (token.startswith("ocr_") or token.startswith("ocrx_")):
            continue
        if token == "ocr_page":
            candidate = "page"
        elif token in ("ocr_carea", "ocrx_block", "ocr_column"):
            candidate = "block"
        elif token == "ocr_par":
            candidate = "paragraph"
        elif token in ("ocr_line", "ocrx_line"):
            candidate = "line"
        elif token == "ocrx_word":
            candidate = "word"
        elif token in LINE_ROLE_TOKENS and not _has_line_descendant(element):
            candidate = "line"
        else:
            continue
        if role is not None:
            raise HocrExtractError("ambiguous role")
        role, token_used = candidate, token
    return (token_used, role) if role else None


def _has_line_descendant(element):
    for child in element.iterdescendants():
        if not isinstance(child.tag, str):
            continue
        toks = _tokens(child.get("class"))
        if "ocr_line" in toks or "ocrx_line" in toks:
            return True
    return False


def _attributes(element, token, role):
    record = {
        "role": role,
        "className": token,
        "tag": element.tag.lower(),
        "id": element.get("id"),
        "lang": element.get("lang"),
        "xmlLang": element.get("xml:lang"),
        "dir": element.get("dir"),
        "bbox": None,
        "textangle": None,
        "properties": {},
    }
    for name, tokens in parse_title(element.get("title")):
        if name in ("order", "cflow"):
            raise HocrExtractError(f"unsupported {name}")
        if name == "bbox":
            record["bbox"] = _bbox(tokens)
        elif name == "textangle":
            if len(tokens) != 1:
                raise HocrExtractError("textangle arity")
            record["textangle"] = _decimal(tokens[0])
        elif name == "baseline" and role == "line":
            if not 2 <= len(tokens) <= 8:
                raise HocrExtractError("baseline arity")
            record["baseline"] = [_decimal(t) for t in tokens]
        elif name == "hardbreak" and role == "line":
            if tokens not in (["0"], ["1"]):
                raise HocrExtractError("hardbreak value")
            record["hardbreak"] = tokens == ["1"]
        elif name == "x_wconf" and role == "word":
            if len(tokens) != 1:
                raise HocrExtractError("x_wconf arity")
            record["hasWconf"] = True
            if DECIMAL_RE.fullmatch(tokens[0]):
                value = _decimal(tokens[0])
                if not 0 <= value <= 100:
                    raise HocrExtractError("x_wconf range")
                record["xWconf"] = value
                record["xWconfToken"] = None
            else:
                record["xWconf"] = None
                record["xWconfToken"] = tokens[0]
        elif name == "ppageno" and role == "page":
            if len(tokens) != 1:
                raise HocrExtractError("ppageno arity")
            record["ppageno"] = _uint(tokens[0])
        elif name == "lpageno" and role == "page":
            if len(tokens) != 1:
                raise HocrExtractError("lpageno arity")
            record["lpageno"] = tokens[0]
        elif name == "image" and role == "page":
            if len(tokens) > 1:
                raise HocrExtractError("image arity")
            record["image"] = tokens[0] if tokens and tokens[0] else None
        elif name == "imagemd5" and role == "page":
            if len(tokens) != 1:
                raise HocrExtractError("imagemd5 arity")
            record["imagemd5"] = tokens[0]
        elif name == "scan_res" and role == "page":
            if len(tokens) == 1:
                both = _uint(tokens[0])
                record["scanRes"] = [both, both]
            elif len(tokens) == 2:
                record["scanRes"] = [_uint(tokens[0]), _uint(tokens[1])]
            else:
                raise HocrExtractError("scan_res arity")
        else:
            record["properties"][name] = list(tokens)
    return record


def _walk_container(element, parent_role, out, counts):
    for child in element:
        if not isinstance(child.tag, str):
            continue
        classified = classify(child)
        if classified is None:
            _walk_container(child, parent_role, out, counts)
            continue
        token, role = classified
        if role == "page":
            raise HocrExtractError("nested page")
        if role == "block":
            if parent_role != "page":
                raise HocrExtractError("block nesting")
            record = _attributes(child, token, role)
            if record["bbox"] is None:
                raise HocrExtractError("block without bbox")
            counts["blocks"] += 1
            out.append(record)
            _walk_container(child, "block", out, counts)
        elif role == "paragraph":
            if parent_role not in ("page", "block"):
                raise HocrExtractError("paragraph nesting")
            counts["paragraphs"] += 1
            out.append(_attributes(child, token, role))
            _walk_container(child, "paragraph", out, counts)
        elif role == "line":
            if parent_role in ("line", "word"):
                raise HocrExtractError("line nesting")
            record = _attributes(child, token, role)
            if record["bbox"] is None:
                raise HocrExtractError("line without bbox")
            record.setdefault("baseline", None)
            record.setdefault("hardbreak", None)
            text, alternatives = text_of(child)
            record["text"] = text
            record["alternatives"] = alternatives
            words = []
            _walk_line(child, words, counts)
            record["wordCount"] = len(words)
            counts["lines"] += 1
            out.append(record)
            out.extend(words)
        else:
            raise HocrExtractError("word outside line")


def _walk_line(element, words, counts):
    for child in element:
        if not isinstance(child.tag, str):
            continue
        tag = child.tag.lower()
        if tag in ("script", "style", "del"):
            continue
        classified = classify(child)
        if classified is None:
            _walk_line(child, words, counts)
            continue
        token, role = classified
        if role != "word":
            raise HocrExtractError("non-word inside line")
        record = _attributes(child, token, role)
        record.setdefault("hasWconf", False)
        record.setdefault("xWconf", None)
        record.setdefault("xWconfToken", None)
        text, alternatives = text_of(child)
        record["text"] = text
        record["alternatives"] = alternatives
        counts["words"] += 1
        words.append(record)
        _check_word_children(child)


def _check_word_children(element):
    for child in element:
        if not isinstance(child.tag, str):
            continue
        if classify(child) is not None:
            raise HocrExtractError("role inside word")
        _check_word_children(child)


def _frame(page_record, elements):
    bbox = page_record["bbox"]
    if bbox and bbox[2] > bbox[0] and bbox[3] > bbox[1]:
        return bbox, "declared"
    union = None
    for record in elements:
        box = record["bbox"]
        if box is None:
            continue
        union = box if union is None else [min(union[0], box[0]), min(union[1], box[1]), max(union[2], box[2]), max(union[3], box[3])]
    if union and union[2] > union[0] and union[3] > union[1]:
        return union, "derivedFromContent"
    return None, "none"


def extract(data):
    document = lxml_html.document_fromstring(data)
    metadata = {}
    for meta in document.iter("meta"):
        name = (meta.get("name") or "").lower()
        if name in METADATA_NAMES:
            if name in metadata:
                raise HocrExtractError(f"duplicate metadata {name}")
            metadata[name] = meta.get("content") or ""
    pages = []

    def find_pages(element):
        classified = classify(element)
        if classified is None:
            for child in element:
                if isinstance(child.tag, str):
                    find_pages(child)
            return
        if classified[1] != "page":
            return
        token = classified[0]
        record = _attributes(element, token, "page")
        for key in ("ppageno", "lpageno", "image", "imagemd5", "scanRes"):
            record.setdefault(key, None)
        elements, counts = [], {"blocks": 0, "paragraphs": 0, "lines": 0, "words": 0}
        _walk_container(element, "page", elements, counts)
        frame, source = _frame(record, elements)
        record["frame"] = frame
        record["frameSource"] = source
        record["counts"] = counts
        record["elements"] = elements
        pages.append(record)

    find_pages(document)
    if not pages:
        raise HocrExtractError("no ocr_page")
    number = metadata.get("ocr-number-of-pages")
    return {
        "system": metadata.get("ocr-system"),
        "capabilities": _tokens(metadata.get("ocr-capabilities")),
        "numberOfPages": int(number.strip()) if number and number.strip().isdigit() and len(number.strip()) <= 10 else None,
        "languages": _tokens(metadata.get("ocr-langs")),
        "scripts": _tokens(metadata.get("ocr-scripts")),
        "pages": pages,
    }
