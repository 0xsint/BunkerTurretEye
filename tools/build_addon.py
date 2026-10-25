"""Standalone re-implementation of Bingus Shared Loader's addon packaging,
so a mod's compiled Stingray resource/archive layout can be built and
inspected without checking out the full loader repository.

Matches scripts/build_addon.py and scripts/archive.py from
https://github.com/CowboyBingus/BingusSharedLoader (as of loader v18).
"""
import argparse
import json
from pathlib import Path
import re
import struct
import uuid
import zipfile

ARCHIVE = "9ba626afa44a3aa3.patch_0"
TYPE = 0xA14E8DFA2CD117E2


def resource_hash(name):
	"""Seed-zero MurmurHash64A over the UTF-8 resource name."""
	data = name.encode("utf-8")
	mask, mix = (1 << 64) - 1, 0xC6A4A7935BD1E995
	value = len(data) * mix & mask
	end = len(data) // 8 * 8
	for (word,) in struct.iter_unpack("<Q", data[:end]):
		word = word * mix & mask
		word ^= word >> 47
		value = (value ^ (word * mix & mask)) * mix & mask
	if data[end:]:
		value = (value ^ int.from_bytes(data[end:], "little")) * mix & mask
	value ^= value >> 47
	value = value * mix & mask
	return value ^ (value >> 47)


def make_archive(resources):
	if not resources:
		raise ValueError("An archive needs at least one resource")
	count = len(resources)
	offset = (104 + 80 * count + 15) & ~15
	entries, body = bytearray(), bytearray(offset)
	for index, (name, resource) in enumerate(sorted(resources.items())):
		entries += struct.pack(
			"<7Q6I", name, TYPE, offset, 0, 0, 0, 0, len(resource), 0, 0, 16, 16, index
		)
		body += resource
		body += b"\0" * (-len(body) % 16)
		offset = len(body)
	header = struct.pack("<III20sQQ24s", 0xF0000011, 1, count, b"", offset, 0, b"")
	types = struct.pack("<IIQIIII", 0, 0, TYPE, count, 0, 16, 16)
	body[: 104 + len(entries)] = header + types + entries
	return bytes(body)


def entry_source(name, source):
	if not re.fullmatch(r"mods/[A-Za-z0-9_]+/[A-Za-z0-9_]+(?:/[A-Za-z0-9_]+)*", name):
		raise ValueError("Use mods/<author>/<entry> with letters, digits and underscores")
	if name == "mods/codex/loader":
		raise ValueError("mods/codex/loader is reserved for the compatibility dispatcher")
	if source.startswith((b"\xef\xbb\xbf", b"\x1b")) or b"\0" in source:
		raise ValueError("Entry must be plaintext UTF-8 Lua without a BOM or bytecode")
	source.decode("utf-8")
	marker = ("-- HD2-Addon: " + name + "\n").encode("utf-8")
	if len(marker) > 256:
		raise ValueError("Entry declaration must fit within 256 bytes including newline")
	if source.startswith(b"-- HD2-Addon:"):
		line, separator, remainder = source.partition(b"\n")
		if not separator or line.rstrip(b"\r") != marker[:-1]:
			raise ValueError("Existing declaration must match the resource name")
		source = remainder
	return marker + source


def build_addon(name, source, guid, output, display_name=None):
	guid = str(uuid.UUID(guid))
	body = entry_source(name, source)
	resource = struct.pack("<II", len(body), 2) + body
	archive = make_archive({resource_hash(name): resource})
	title = display_name or name
	description = "Requires Bingus Shared Loader v15 or newer / API 1. Enable both and deploy."
	manifest = {
		"Version": 1,
		"Guid": guid,
		"Name": title,
		"Description": description,
		"Options": [{"Name": title, "Description": description, "Include": ["Addon"]}],
	}
	files = {
		"manifest.json": (json.dumps(manifest, indent=2) + "\n").encode(),
		"Addon/" + ARCHIVE: archive,
		"Addon/" + ARCHIVE + ".stream": b"",
		"Addon/" + ARCHIVE + ".gpu_resources": b"",
	}
	output = Path(output)
	output.parent.mkdir(parents=True, exist_ok=True)
	with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED) as package:
		for path, content in sorted(files.items()):
			info = zipfile.ZipInfo(path, date_time=(1980, 1, 1, 0, 0, 0))
			info.compress_type = zipfile.ZIP_DEFLATED
			info.external_attr = 0o100644 << 16
			package.writestr(info, content)
	return output, body, resource, archive


def print_readable(name, body, resource, archive):
	print("=== Readable Stingray data ===")
	print(f"Resource name        : {name}")
	print(f"Resource hash (u64)  : 0x{resource_hash(name):016X}")
	print(f"Envelope version     : 2")
	print(f"Body length (bytes)  : {len(body)}")
	print(f"Archive filename     : {ARCHIVE}")
	print(f"Archive size (bytes) : {len(archive)}")
	print(f"Archive type id      : 0x{TYPE:016X}")
	print("--- Embedded declaration + source (first 400 chars) ---")
	print(body[:400].decode("utf-8", errors="replace"))


def main():
	parser = argparse.ArgumentParser(description=__doc__)
	parser.add_argument("--name", required=True, help="Game resource path, without .lua")
	parser.add_argument("--entry", required=True, type=Path, help="Plain UTF-8 Lua initialization script")
	parser.add_argument("--guid", required=True, help="Your mod UUID; reuse it for subsequent releases")
	parser.add_argument("--output", required=True, type=Path)
	parser.add_argument("--display-name")
	args = parser.parse_args()
	if args.entry.resolve() == args.output.resolve():
		parser.error("Output must not overwrite the entry source")
	output, body, resource, archive = build_addon(
		args.name, args.entry.read_bytes(), args.guid, args.output, args.display_name
	)
	print_readable(args.name, body, resource, archive)
	print(f"\nBuilt {output}")


if __name__ == "__main__":
	main()
