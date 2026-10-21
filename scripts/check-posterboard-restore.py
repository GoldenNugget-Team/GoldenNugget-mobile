#!/usr/bin/env python3
"""Exercise native PosterBoard graph merge and the real delta injector, offline.

Optional argument: a captured <udid> backup directory. It is read only.
"""
import hashlib
import plistlib
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
DOMAIN = 'AppDomain-com.apple.PosterBoard'
DB_PATH = 'Library/Application Support/PRBPosterExtensionDataStore/61/PBFPosterExtensionDataStoreSQLiteDatabase.sqlite3'
SCHEMA = 'CREATE TABLE Files (fileID TEXT PRIMARY KEY, domain TEXT, relativePath TEXT, flags INTEGER, file BLOB)'
support = (ROOT / 'scripts/posterboard-identity-check.swift').read_text().split('struct TweakPayload', 1)[1].split('enum PosterBoardResources', 1)[0]
support = 'struct TweakPayload' + support.split('enum PosterBoardTendie', 1)[0]
support = support[:support.index('enum PosterBoardPosterType')]
support = support.replace('    let source: URL?', '    let source: URL?\n    var owner: Int? { nil }')
harness = r'''
enum PosterBoard {
    static let domain = "AppDomain-com.apple.PosterBoard"
    static let storeDirectoryName = "PRBPosterExtensionDataStore"
    static let databaseFileName = "PBFPosterExtensionDataStoreSQLiteDatabase.sqlite3"
}
// Minimal SQL adapter; the production merge and delta injector run unchanged.
struct ManifestStore {
    let deviceDir: URL
    static func fileID(domain: String, relativePath: String) -> String {
        Insecure.SHA1.hash(data: Data("\(domain)-\(relativePath)".utf8)).map { String(format: "%02x", $0) }.joined()
    }
    func payloadURL(forFileID id: String) -> URL { deviceDir.appendingPathComponent("\(id.prefix(2))/\(id)") }
    func maxInode() -> Int { 10_000_000 }
    func upsert(fileID: String, domain: String, relativePath: String, flags: Int32, blob: Data) throws {
        var db: OpaquePointer?
        precondition(sqlite3_open(deviceDir.appendingPathComponent("Manifest.db").path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        precondition(sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO Files VALUES (?,?,?,?,?)", -1, &stmt, nil) == SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, fileID, -1, transient)
        sqlite3_bind_text(stmt, 2, domain, -1, transient)
        sqlite3_bind_text(stmt, 3, relativePath, -1, transient)
        sqlite3_bind_int(stmt, 4, flags)
        _ = blob.withUnsafeBytes { sqlite3_bind_blob(stmt, 5, $0.baseAddress, Int32($0.count), transient) }
        precondition(sqlite3_step(stmt) == SQLITE_DONE)
    }
}
let source = URL(fileURLWithPath: CommandLine.arguments[1])
let target = URL(fileURLWithPath: CommandLine.arguments[2])
let baseline = target.deletingLastPathComponent().appendingPathComponent(target.lastPathComponent + "-baseline")
try PosterBoardSnapshot.retainBaseline(from: source, at: baseline)
let snapshot = try PosterBoardSnapshot.merge(from: source, into: target)
let addedPath = "Library/Application Support/PRBPosterExtensionDataStore/61/Extensions/test-provider/descriptors/NEW/asset.bin"
_ = try TweakInjector.inject(into: target, payloads: [TweakPayload(domain: PosterBoard.domain, relativePath: addedPath, contents: Data("new wallpaper".utf8))], preservedDirectories: snapshot.directories, preservedFileMetadata: snapshot.fileMetadata)
if CommandLine.arguments.count > 3 && CommandLine.arguments[3] == "patch" {
    let database = try PosterBoardSnapshot.records(in: source).first { PosterBoardSnapshot.storeVersion(relativePath: $0.path) != nil }!
    _ = try TweakInjector.inject(into: target, payloads: [TweakPayload(domain: PosterBoard.domain, relativePath: database.path, contents: Data("new db".utf8))], preservedDirectories: snapshot.directories, preservedFileMetadata: snapshot.fileMetadata)
}
print("Native PosterBoard merge and delta injection passed (\(snapshot.directories.count) original directories)")
'''

def file_id(path, domain=DOMAIN):
    return hashlib.sha1(f'{domain}-{path}'.encode()).hexdigest()


def add(conn, root, path, flags, data=b'', domain=DOMAIN):
    ident = file_id(path, domain)
    conn.execute('INSERT INTO Files VALUES (?,?,?,?,?)', (ident, domain, path, flags, b'original-metadata:' + path.encode()))
    if flags == 1:
        dest = root / ident[:2] / ident
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(data)


def rows(root):
    with sqlite3.connect(root / 'Manifest.db') as conn:
        return conn.execute('SELECT * FROM Files WHERE domain=? ORDER BY fileID', (DOMAIN,)).fetchall()


def run_and_verify(binary, source, target, patch=False):
    original = rows(source)
    target.mkdir()
    with sqlite3.connect(target / 'Manifest.db') as conn:
        conn.execute(SCHEMA)
        add(conn, target, 'Library/unrelated.bin', 1, b'keep', 'HomeDomain')
    subprocess.run([str(binary), str(source), str(target), *( ["patch"] if patch else [])], check=True)
    with sqlite3.connect(target / 'Manifest.db') as conn:
        for row in original:
            current = conn.execute('SELECT * FROM Files WHERE fileID=?', (row[0],)).fetchone()
            if patch and row[2] == DB_PATH:
                before = plistlib.loads(row[4])
                expected = plistlib.loads(row[4])
                expected['$objects'][1]['Size'] = 6
                assert plistlib.loads(current[4]) == expected, 'native metadata or UID graph corrupted during donor patch'
                assert (target / row[0][:2] / row[0]).read_bytes() == b'new db'
                print('PASS: same-path database delta preserves native protection, inode, ownership and keyed UIDs')
                continue
            assert current == row, f'native metadata changed: {row[2]}'
            if row[3] == 1:
                assert (target / row[0][:2] / row[0]).read_bytes() == (source / row[0][:2] / row[0]).read_bytes(), row[2]
        added = conn.execute("SELECT file FROM Files WHERE domain=? AND relativePath LIKE '%/NEW/asset.bin'", (DOMAIN,)).fetchone()[0]
        archive = plistlib.loads(added)
        info = archive['$objects'][1]
        assert info['ProtectionClass'] == 4 and info['UserID'] == 501
        assert info['Mode'] & 0o170000 == 0o100000
        assert conn.execute("SELECT count(*) FROM Files WHERE domain='HomeDomain'").fetchone()[0] == 1
        assert conn.execute("SELECT count(*) FROM Files WHERE domain='AppDomain-foreign'").fetchone()[0] == 0
    assert rows(source) == original, 'source snapshot mutated'
    assert rows(target.with_name(target.name + '-baseline')) == original, 'recovery baseline lost native records'
    print(f'PASS: {len(original)} native records and all file bytes survive delta injection')


with tempfile.TemporaryDirectory(prefix='pb-restore-') as work:
    work = Path(work)
    main = work / 'main.swift'
    main.write_text((ROOT / 'Nugget/Core/PosterBoardSnapshot.swift').read_text() + '\n' + support + '\n' +
                    (ROOT / 'Nugget/Core/MBFileBlob.swift').read_text() + '\n' +
                    (ROOT / 'Nugget/Core/TweakInjector.swift').read_text() + '\n' + harness)
    binary = work / 'check'
    subprocess.run(['xcrun', 'swiftc', '-warnings-as-errors', str(main), '-o', str(binary)], check=True)
    source = work / 'source'
    source.mkdir()
    with sqlite3.connect(source / 'Manifest.db') as conn:
        conn.execute(SCHEMA)
        for path in ['', 'Library', 'Library/Application Support', 'Library/Application Support/PRBPosterExtensionDataStore',
                     'Library/Application Support/PRBPosterExtensionDataStore/61',
                     'Library/Application Support/PRBPosterExtensionDataStore/61/Extensions',
                     'Library/Application Support/PRBPosterExtensionDataStore/61/Extensions/test-provider',
                     'Library/Application Support/PRBPosterExtensionDataStore/61/Extensions/test-provider/descriptors',
                     'Library/Application Support/PRBPosterExtensionDataStore/61/Extensions/empty-provider/descriptors']:
            add(conn, source, path, 2)
        add(conn, source, DB_PATH, 1, b'snapshot database')
        add(conn, source, 'Library/existing.bin', 1, b'existing wallpaper')
        add(conn, source, 'Library/current-link', 4)
        add(conn, source, 'secret.bin', 1, b'foreign app', 'AppDomain-foreign')
    run_and_verify(binary, source, work / 'target')
    # Device manifests can retain WAL mode without an accompanying WAL/SHM.
    # Exercise opening that uploaded shape, not only our DELETE-mode fixture.
    with sqlite3.connect(source / 'Manifest.db') as conn:
        assert conn.execute('PRAGMA journal_mode=WAL').fetchone()[0] == 'wal'
    assert (source / 'Manifest.db').read_bytes()[18:20] == b'\x02\x02'
    run_and_verify(binary, source, work / 'wal-target')
    print('PASS: checkpointed WAL manifest without uploaded sidecars is readable')
    absent = work / 'absent-source'
    absent.mkdir()
    result = subprocess.run([str(binary), str(absent), str(work / 'absent-target')], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    assert result.returncode != 0
    assert not (absent / 'Manifest.db').exists(), 'missing source manifest was silently created'
    print('PASS: opening a missing source never creates an empty manifest')
    missing = file_id('Library/existing.bin')
    (source / missing[:2] / missing).unlink()
    incomplete = work / 'incomplete-target'
    incomplete.mkdir()
    with sqlite3.connect(incomplete / 'Manifest.db') as conn:
        conn.execute(SCHEMA)
    result = subprocess.run([str(binary), str(source), str(incomplete)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    assert result.returncode != 0
    assert rows(incomplete) == [], 'incomplete snapshot modified restore manifest'
    assert not list(incomplete.glob('[0-9a-f][0-9a-f]/*')), 'incomplete snapshot copied partial payloads'
    print('PASS: missing payload aborts before modifying the restore backup')
    if len(sys.argv) > 1:
        run_and_verify(binary, Path(sys.argv[1]).resolve(), work / 'real-target')
        run_and_verify(binary, Path(sys.argv[1]).resolve(), work / 'patched-target', patch=True)
