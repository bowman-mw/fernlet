#!/usr/bin/env python3
"""Bounded, read-only XLSX row streaming using only Python's standard library."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import PurePosixPath
import re
import xml.etree.ElementTree as ET
import zipfile


MAIN_NS = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
REL_NS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
PKG_REL_NS = "http://schemas.openxmlformats.org/package/2006/relationships"
MAX_SHEETS = 64
MAX_SHARED_STRINGS = 2_000_000
MAX_SHARED_STRING_BYTES = 64_000_000
MAX_COLUMNS = 512
MAX_ROWS = 100_000
MAX_CELLS_PER_ROW = 512
MAX_CELLS_PER_SHEET = 2_000_000
MAX_CELL_TEXT_BYTES = 1_000_000
MAX_ARCHIVE_MEMBERS = 128
MAX_ARCHIVE_MEMBER_BYTES = 16_000_000
MAX_ARCHIVE_TOTAL_BYTES = 64_000_000
MAX_ARCHIVE_COMPRESSION_RATIO = 128
CELL_REFERENCE = re.compile(r"^([A-Z]+)([0-9]+)$")


class XLSXError(ValueError):
    """Raised when a workbook violates the declared bounded source contract."""


@dataclass(frozen=True)
class SheetInfo:
    name: str
    path: str
    state: str


def _validate_archive(archive: zipfile.ZipFile) -> None:
    members = archive.infolist()
    if not members or len(members) > MAX_ARCHIVE_MEMBERS:
        raise XLSXError(f"workbook archive member count exceeds {MAX_ARCHIVE_MEMBERS}")
    total_bytes = 0
    names: set[str] = set()
    for info in members:
        name = info.filename
        if not name or name in names or name.startswith("/") or ".." in name.split("/"):
            raise XLSXError(f"workbook archive has unsafe or duplicate member: {name!r}")
        names.add(name)
        if info.flag_bits & 0x1:
            raise XLSXError(f"workbook archive has encrypted member: {name}")
        if info.file_size < 0 or info.file_size > MAX_ARCHIVE_MEMBER_BYTES:
            raise XLSXError(f"workbook member expansion exceeds {MAX_ARCHIVE_MEMBER_BYTES}: {name}")
        total_bytes += info.file_size
        if total_bytes > MAX_ARCHIVE_TOTAL_BYTES:
            raise XLSXError(f"workbook total expansion exceeds {MAX_ARCHIVE_TOTAL_BYTES}")
        if info.file_size and (info.compress_size <= 0 or info.file_size > info.compress_size * MAX_ARCHIVE_COMPRESSION_RATIO):
            raise XLSXError(f"workbook member compression ratio exceeds {MAX_ARCHIVE_COMPRESSION_RATIO}: {name}")


def _bounded_text(value: str | None, label: str) -> str | None:
    if value is not None and len(value.encode("utf-8")) > MAX_CELL_TEXT_BYTES:
        raise XLSXError(f"{label} exceeds {MAX_CELL_TEXT_BYTES} bytes")
    return value


def _qualified(namespace: str, local: str) -> str:
    return f"{{{namespace}}}{local}"


def _column_index(reference: str) -> int:
    match = CELL_REFERENCE.fullmatch(reference)
    if match is None:
        raise XLSXError(f"invalid cell reference: {reference!r}")
    value = 0
    for character in match.group(1):
        value = value * 26 + ord(character) - ord("A") + 1
    index = value - 1
    if index >= MAX_COLUMNS:
        raise XLSXError(f"cell column exceeds {MAX_COLUMNS}: {reference}")
    return index


def _shared_strings(archive: zipfile.ZipFile) -> list[str]:
    path = "xl/sharedStrings.xml"
    if path not in archive.namelist():
        return []
    strings: list[str] = []
    total_bytes = 0
    with archive.open(path) as source:
        for event, element in ET.iterparse(source, events=("end",)):
            if element.tag != _qualified(MAIN_NS, "si"):
                continue
            value = _bounded_text("".join(node.text or "" for node in element.iter(_qualified(MAIN_NS, "t"))), "shared string")
            total_bytes += len((value or "").encode("utf-8"))
            if total_bytes > MAX_SHARED_STRING_BYTES:
                raise XLSXError(f"shared-string bytes exceed {MAX_SHARED_STRING_BYTES}")
            strings.append(value or "")
            element.clear()
            if len(strings) > MAX_SHARED_STRINGS:
                raise XLSXError(f"shared-string count exceeds {MAX_SHARED_STRINGS}")
    return strings


def workbook_sheets(archive: zipfile.ZipFile) -> list[SheetInfo]:
    _validate_archive(archive)
    relationship_tree = ET.parse(archive.open("xl/_rels/workbook.xml.rels"))
    relationships = {
        relation.attrib["Id"]: relation.attrib["Target"]
        for relation in relationship_tree.getroot().findall(_qualified(PKG_REL_NS, "Relationship"))
    }
    workbook_tree = ET.parse(archive.open("xl/workbook.xml"))
    sheet_parent = workbook_tree.getroot().find(_qualified(MAIN_NS, "sheets"))
    if sheet_parent is None:
        raise XLSXError("workbook has no sheets collection")
    sheets: list[SheetInfo] = []
    for element in sheet_parent.findall(_qualified(MAIN_NS, "sheet")):
        relation_id = element.attrib.get(_qualified(REL_NS, "id"))
        target = relationships.get(relation_id or "")
        if target is None:
            raise XLSXError(f"missing worksheet relationship for {element.attrib.get('name')!r}")
        normalized = str(PurePosixPath("xl") / target).replace("xl/../", "")
        sheets.append(SheetInfo(element.attrib["name"], normalized, element.attrib.get("state", "visible")))
        if len(sheets) > MAX_SHEETS:
            raise XLSXError(f"sheet count exceeds {MAX_SHEETS}")
    return sheets


def _cell_text(cell: ET.Element, shared_strings: list[str]) -> str | None:
    if cell.find(_qualified(MAIN_NS, "f")) is not None:
        raise XLSXError(f"formula cell is not accepted: {cell.attrib.get('r', '?')}")
    cell_type = cell.attrib.get("t")
    if cell_type == "inlineStr":
        inline = cell.find(_qualified(MAIN_NS, "is"))
        value = "" if inline is None else "".join(node.text or "" for node in inline.iter(_qualified(MAIN_NS, "t")))
        return _bounded_text(value, "inline cell string")
    value = cell.find(_qualified(MAIN_NS, "v"))
    if value is None or value.text is None:
        return None
    if cell_type == "s":
        index = int(value.text)
        if index < 0 or index >= len(shared_strings):
            raise XLSXError(f"shared-string index out of range: {index}")
        return shared_strings[index]
    if cell_type == "b":
        return "true" if value.text == "1" else "false"
    return _bounded_text(value.text, "cell text")


def iter_sheet_rows(path: str, sheet_name: str):
    """Yield `(row_number, [raw cell text...])` without extracting or modifying `path`."""
    with zipfile.ZipFile(path) as archive:
        _validate_archive(archive)
        shared_strings = _shared_strings(archive)
        sheets = workbook_sheets(archive)
        matches = [sheet for sheet in sheets if sheet.name == sheet_name]
        if len(matches) != 1:
            raise XLSXError(f"expected one sheet named {sheet_name!r}; found {len(matches)}")
        sheet = matches[0]
        if sheet.state != "visible":
            raise XLSXError(f"required sheet {sheet_name!r} is not visible")
        with archive.open(sheet.path) as source:
            row_count = 0
            cell_count = 0
            for event, row in ET.iterparse(source, events=("end",)):
                if row.tag != _qualified(MAIN_NS, "row"):
                    continue
                row_count += 1
                if row_count > MAX_ROWS:
                    raise XLSXError(f"sheet {sheet_name!r} exceeds {MAX_ROWS} rows")
                try:
                    row_number = int(row.attrib.get("r", row_count))
                except ValueError as error:
                    raise XLSXError(f"sheet {sheet_name!r} has invalid row reference") from error
                values: list[str | None] = []
                row_cells = 0
                for cell in row:
                    if cell.tag != _qualified(MAIN_NS, "c"):
                        continue
                    row_cells += 1
                    cell_count += 1
                    if row_cells > MAX_CELLS_PER_ROW or cell_count > MAX_CELLS_PER_SHEET:
                        raise XLSXError(f"sheet {sheet_name!r} exceeds cell bounds")
                    reference = cell.attrib.get("r")
                    if reference is None:
                        raise XLSXError(f"sheet {sheet_name!r} row {row_number} has unaddressed cell")
                    column = _column_index(reference)
                    if column >= len(values):
                        values.extend([None] * (column + 1 - len(values)))
                    values[column] = _cell_text(cell, shared_strings)
                yield row_number, values
                row.clear()
