#!/usr/bin/env python3
"""The tagged tree's checks for crate-admit's step, over its checkout read as data: the workspace's
manifests parsed as TOML, its cargo configuration and its toolchain files. Nothing in the tree runs,
and a symbolic link is a file, never followed.

    admit-tree.py <tree> <version> <crates json>

Run with `python3 -I` (3.11 or later, for tomllib). Exit 0 with one JSON line, `{"order": [...],
"toolchain": "..."}`: the publishable crates, each after every one it depends on (ties by name),
and the one exact release rust-toolchain.toml names. Exit 1 with the finding that refuses the tree
on stdout, the first in this order: manifests, versions and crates, each crate's description and
licence, cargo configuration, Cargo.lock's sources, rust-toolchain, rust-toolchain.toml, the
dependency order. Exit 3 with what could not be read, and 64 on a bad invocation.
"""

import glob
import json
import os
import stat
import sys
import tomllib
from pathlib import PurePosixPath

# The keys a root .cargo/config.toml may hold: P 2.2's rule, which has no form but cargo
# configuration.
CONFIG_KEYS = ("registry.global-min-publish-age", "resolver.incompatible-publish-age")

ROOT = PurePosixPath(".")


class Finding(Exception):
    """The tree is refused."""


class Unreadable(Exception):
    """The checkout could not be read."""


def shown(path: PurePosixPath) -> str:
    return str(path)


def key(path: PurePosixPath) -> tuple[str, ...]:
    """A path's order: by component, as the gate's sets of paths sort."""
    return path.parts


def walk(root: str) -> set[PurePosixPath]:
    """Every file of the checkout but git's own at its root, relative to it."""
    files = set()
    pending = [ROOT]
    while pending:
        directory = pending.pop()
        full = os.path.join(root, str(directory))
        try:
            entries = list(os.scandir(full))
        except OSError as error:
            raise Unreadable(f"{full}: {error}") from error
        for entry in entries:
            relative = directory / entry.name
            try:
                is_directory = entry.is_dir(follow_symlinks=False)
            except OSError as error:
                raise Unreadable(str(error)) from error
            if is_directory:
                if relative != PurePosixPath(".git"):
                    pending.append(relative)
            else:
                files.add(relative)
    return files


def read_toml(root: str, path: PurePosixPath) -> dict:
    """A file of the tree as TOML, refused when it is a link, absent or not TOML."""
    full = os.path.join(root, str(path))
    try:
        meta = os.lstat(full)
    except OSError:
        raise Finding(f"{shown(path)}: absent") from None
    if not stat.S_ISREG(meta.st_mode):
        raise Finding(f"{shown(path)}: not a regular file")
    try:
        with open(full, "rb") as f:
            data = f.read()
    except OSError as error:
        raise Unreadable(f"{shown(path)}: {error}") from error
    try:
        return tomllib.loads(data.decode("utf-8"))
    except UnicodeDecodeError:
        raise Finding(f"{shown(path)}: not TOML: it is not UTF-8") from None
    except tomllib.TOMLDecodeError as error:
        raise Finding(f"{shown(path)}: not TOML: {error}") from None


def reason_of(finding: Finding, path: PurePosixPath) -> str:
    """A manifest finding's reason, without its path."""
    return str(finding).removeprefix(f"{shown(path)}: ")


def inside(base: PurePosixPath, path: str) -> PurePosixPath | None:
    """`base` joined with the relative `path`, lexically, while it stays inside the tree."""
    if path.startswith("/"):
        return None
    parts = list(base.parts)
    for part in path.split("/"):
        if part in ("", "."):
            continue
        if part == "..":
            if not parts:
                return None
            parts.pop()
        else:
            parts.append(part)
    return PurePosixPath(*parts) if parts else ROOT


def table(value) -> dict | None:
    return value if isinstance(value, dict) else None


def dependency(directory: PurePosixPath, name: str, value, workspace: dict | None):
    """A dependency's path relative to the tree and whether it carries a version, inheritance from
    [workspace.dependencies] resolved; None when it is no path dependency."""
    spec = table(value)
    if spec is None:
        return None
    if spec.get("workspace") is True:
        inherited = table((table((workspace or {}).get("dependencies")) or {}).get(name))
        if inherited is None or not isinstance(inherited.get("path"), str):
            return None
        path = inside(ROOT, inherited["path"])
        return None if path is None else (path, "version" in inherited)
    if not isinstance(spec.get("path"), str):
        return None
    path = inside(directory, spec["path"])
    return None if path is None else (path, "version" in spec)


KINDS = (
    ("dependencies", False),
    ("build-dependencies", False),
    ("build_dependencies", False),
    ("dev-dependencies", True),
    ("dev_dependencies", True),
)


def path_dependencies(directory: PurePosixPath, manifest: dict, workspace: dict | None):
    """Each path dependency on another directory of the tree, and whether cargo keeps it in the
    published crate: a normal or build dependency always, a development one only with a version."""
    tables = []
    for name, dev in KINDS:
        found = table(manifest.get(name))
        if found is not None:
            tables.append((found, dev))
    for target in (table(manifest.get("target")) or {}).values():
        target = table(target)
        if target is None:
            continue
        for name, dev in KINDS:
            found = table(target.get(name))
            if found is not None:
                tables.append((found, dev))
    out = []
    for found, dev in tables:
        for name, value in found.items():
            dep = dependency(directory, name, value, workspace)
            if dep is not None:
                out.append((dep[0], not dev or dep[1]))
    return out


MISSING = object()


def field(package: dict, workspace: dict | None, name: str):
    """A field of [package], or [workspace.package]'s where the package inherits it."""
    value = package.get(name, MISSING)
    if isinstance(value, dict) and value.get("workspace") is True:
        return (table((workspace or {}).get("package")) or {}).get(name, MISSING)
    return value


def starts_with(path: PurePosixPath, prefix: PurePosixPath) -> bool:
    return prefix == ROOT or path.parts[: len(prefix.parts)] == prefix.parts


def members(root: str, files: set[PurePosixPath], manifest: dict) -> set[PurePosixPath]:
    """The workspace's members as cargo finds them: the root package; each directory a `members`
    glob matches that holds a manifest; every path dependency of a member inside the tree; less
    whatever lies under an `exclude` path. Without [workspace], the root package alone."""
    found = set()
    if "package" in manifest:
        found.add(ROOT)
    workspace = table(manifest.get("workspace"))
    if workspace is None:
        return found

    def strings(name: str) -> list[str]:
        values = workspace.get(name)
        return [v for v in values if isinstance(v, str)] if isinstance(values, list) else []

    excluded = [e for e in (inside(ROOT, x) for x in strings("exclude")) if e is not None]

    def is_member(directory: PurePosixPath) -> bool:
        return directory / "Cargo.toml" in files and not any(starts_with(directory, e) for e in excluded)

    for pattern in strings("members"):
        # cargo's matcher, the glob crate, takes a leading dot under `*` and walks one component
        # at a time, as Python's glob does with these options.
        for match in glob.glob(pattern, root_dir=root, recursive=True, include_hidden=True):
            if os.path.isabs(match):
                continue
            directory = PurePosixPath(match)
            if is_member(directory):
                found.add(directory)
    pending = sorted(found, key=key)
    while pending:
        directory = pending.pop()
        member = read_toml(root, directory / "Cargo.toml")
        for path, _ in path_dependencies(directory, member, workspace):
            if is_member(path) and path not in found:
                found.add(path)
                pending.append(path)
    return found


def publishable(root: str, files: set[PurePosixPath]) -> dict:
    """The members `cargo package --workspace` packages for crates.io, by directory: those with a
    version and a `publish` that admits crates.io."""
    manifest = read_toml(root, PurePosixPath("Cargo.toml"))
    workspace = table(manifest.get("workspace"))
    crates = {}
    for directory in sorted(members(root, files, manifest), key=key):
        path = directory / "Cargo.toml"
        member = read_toml(root, path)
        package = table(member.get("package"))
        if package is None:
            continue
        name = package.get("name")
        if not isinstance(name, str):
            raise Finding(f"{shown(path)}: names no package")
        version = field(package, workspace, "version")
        if version is MISSING:
            version = None
        elif not isinstance(version, str):
            raise Finding(f"{shown(path)}: its version is not a string")
        publish = field(package, workspace, "publish")
        if publish is MISSING:
            publish = version is not None
        elif isinstance(publish, bool):
            pass
        elif isinstance(publish, list):
            publish = "crates-io" in publish
        else:
            raise Finding(f"{shown(path)}: its publish is neither a boolean nor a list")
        if version is None or not publish:
            continue
        depends = {p for p, kept in path_dependencies(directory, member, workspace) if kept and p != directory}
        metadata = {f: field(package, workspace, f) for f in ("description", "license", "license-file")}
        crates[directory] = {"name": name, "version": version, "depends": depends, "metadata": metadata}
    return crates


def stated(value) -> bool:
    """A manifest field crates.io counts as given: a string that is not empty."""
    return isinstance(value, str) and value != ""


def metadata(crates: dict) -> None:
    """Each crate's manifest gives what crates.io refuses a crate without (its publish endpoint's
    required fields): a description, and a license or a license-file."""
    for c in sorted(crates.values(), key=lambda c: c["name"]):
        if not stated(c["metadata"]["description"]):
            raise Finding(f"{c['name']}'s manifest gives no description, and crates.io refuses a crate without one")
        if not (stated(c["metadata"]["license"]) or stated(c["metadata"]["license-file"])):
            raise Finding(f"{c['name']}'s manifest gives neither license nor license-file, and crates.io refuses a crate without one")


def leaves(values: dict, prefix: str, out: list[str]) -> None:
    """Every key holding a value other than a table, dotted, in key order."""
    for name in sorted(values):
        dotted = name if not prefix else f"{prefix}.{name}"
        if isinstance(values[name], dict):
            leaves(values[name], dotted, out)
        else:
            out.append(dotted)


def cargo_config(root: str, path: PurePosixPath) -> None:
    """A root .cargo/config.toml holding only CONFIG_KEYS; any other cargo configuration refused."""
    if path != PurePosixPath(".cargo/config.toml"):
        raise Finding(f"{shown(path)}: a cargo configuration other than the root's .cargo/config.toml")
    keys: list[str] = []
    leaves(read_toml(root, path), "", keys)
    for name in keys:
        if name not in CONFIG_KEYS:
            raise Finding(f"{shown(path)}: sets {name}, and only {' and '.join(CONFIG_KEYS)} may be set")


def git_sources(root: str, files: set[PurePosixPath]) -> None:
    """No package of the root's Cargo.lock comes from git, whatever the project's checks admit."""
    path = PurePosixPath("Cargo.lock")
    if path not in files:
        return
    packages = read_toml(root, path).get("package")
    for package in packages if isinstance(packages, list) else []:
        package = table(package)
        if package is None:
            continue
        source = package.get("source")
        source = source if isinstance(source, str) else ""
        if source.startswith("git+"):
            name = package.get("name")
            name = name if isinstance(name, str) else ""
            raise Finding(f"Cargo.lock takes {name} from {source}, and a release takes registry sources alone")


def toolchain(root: str, files: set[PurePosixPath]) -> str:
    """The one exact release the root's rust-toolchain.toml names, with no `path`."""
    path = PurePosixPath("rust-toolchain.toml")
    if path not in files:
        raise Finding("rust-toolchain.toml is absent from the root")
    try:
        document = read_toml(root, path)
    except Finding as finding:
        raise Finding(f"rust-toolchain.toml {reason_of(finding, path)}") from None
    section = table(document.get("toolchain"))
    if section is not None and "path" in section:
        raise Finding("rust-toolchain.toml names a path")
    channel = (section or {}).get("channel")
    channel = channel if isinstance(channel, str) else ""
    parts = channel.split(".")
    if not (len(parts) == 3 and all(p and p.isascii() and p.isdigit() for p in parts)):
        raise Finding(f"rust-toolchain.toml names {json.dumps(channel, ensure_ascii=False)}, not one exact release")
    return channel


def order(crates: dict) -> list[str]:
    """The crates, each after every crate it depends on; ties by name."""
    left = {c["name"]: {crates[d]["name"] for d in c["depends"] if d in crates} for c in crates.values()}
    out = []
    while left:
        ready = sorted(name for name, depends in left.items() if not depends)
        if not ready:
            raise Finding(f"the crates {', '.join(sorted(left))} depend on each other in a cycle")
        left.pop(ready[0])
        for depends in left.values():
            depends.discard(ready[0])
        out.append(ready[0])
    return out


def check(root: str, version: str, listed: list[str]) -> dict:
    files = walk(root)
    crates = publishable(root, files)
    for c in crates.values():
        if c["version"] != version:
            raise Finding(f"{c['name']} is version {c['version']}, and the tag is v{version}")
    names = sorted({c["name"] for c in crates.values()})
    wanted = sorted(listed)
    if names != wanted or len(names) != len(crates):
        raise Finding(
            f"the publishable crates are [{', '.join(c['name'] for c in crates.values())}],"
            f" and the project's are [{', '.join(wanted)}]"
        )
    metadata(crates)
    ordered = sorted(files, key=key)
    for path in ordered:
        if path.parent.name == ".cargo" and path.name in ("config", "config.toml"):
            cargo_config(root, path)
    git_sources(root, files)
    for path in ordered:
        if path.name == "rust-toolchain":
            raise Finding(f"{shown(path)} is a rust-toolchain file, which rustup reads before rust-toolchain.toml")
    channel = toolchain(root, files)
    return {"order": order(crates), "toolchain": channel}


def main(argv: list[str]) -> int:
    if len(argv) != 4:
        print("usage: admit-tree.py <tree> <version> <crates json>", file=sys.stderr)
        return 64
    try:
        listed = json.loads(argv[3])
    except json.JSONDecodeError:
        listed = None
    if not isinstance(listed, list) or not all(isinstance(c, str) for c in listed):
        print("usage: admit-tree.py <tree> <version> <crates json>: the crates are a JSON list of names", file=sys.stderr)
        return 64
    try:
        facts = check(argv[1], argv[2], listed)
    except Finding as finding:
        print(finding)
        return 1
    except Unreadable as unreadable:
        print(unreadable)
        return 3
    print(json.dumps(facts, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
