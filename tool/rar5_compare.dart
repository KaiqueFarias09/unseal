import 'dart:convert' as convert;
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'package:unseal/src/features/comic/archive/rar5_archive.dart';
import 'package:unseal/src/features/comic/archive/rar5_decoder.dart';
import 'package:unseal/src/foundation/archive/zip_byte_source.dart';
import 'package:unseal/src/foundation/exceptions/unseal_exception.dart';

/// Byte-for-byte RAR 5 acceptance comparison against the two pinned
/// oracles:
///
/// 1. rardecode (Go) at `ad22ba91a2ab` — the port's base. Requires the
///    Go toolchain; the first run downloads the pinned module.
/// 2. libarchive via `bsdtar` (Unseal develops against libarchive
///    3.7.4; the format source reference is pinned at `87dec938`).
///
/// Every file entry of every archive is decoded through Unseal's RAR 5
/// decoder and compared byte-for-byte with both oracles' extraction.
/// A missing oracle, an oracle error, or one differing byte fails the
/// run with a non-zero exit code — SKIP is never a pass.
///
/// Usage:
/// ```
/// dart run tool/rar5_compare.dart <archive.rar> [more.rar ...] \
///   [--oracle=rardecode|libarchive|both] [--bsdtar=/usr/bin/bsdtar] \
///   [--workdir=build/rar5-compare]
/// ```
///
/// The Go oracle is built into `--workdir`; keep that directory out of
/// Git (build/ is ignored).
void main(final List<String> arguments) {
  final archives = <String>[];
  var oracle = 'both';
  var bsdtar = '/usr/bin/bsdtar';
  var workDir = 'build/rar5-compare';
  var allowReject = false;
  for (final argument in arguments) {
    if (argument.startsWith('--oracle=')) {
      oracle = argument.substring('--oracle='.length);
    } else if (argument.startsWith('--bsdtar=')) {
      bsdtar = argument.substring('--bsdtar='.length);
    } else if (argument.startsWith('--workdir=')) {
      workDir = argument.substring('--workdir='.length);
    } else if (argument == '--allow-reject') {
      allowReject = true;
    } else {
      archives.add(argument);
    }
  }
  if (archives.isEmpty) {
    stderr.writeln(
      'usage: dart run tool/rar5_compare.dart <archive.rar> '
      '[--oracle=rardecode|libarchive|both] [--bsdtar=path] [--workdir=dir]',
    );
    exit(2);
  }
  final useRardecode = oracle == 'both' || oracle == 'rardecode';
  final useLibarchive = oracle == 'both' || oracle == 'libarchive';
  if (oracle != 'both' && oracle != 'rardecode' && oracle != 'libarchive') {
    stderr.writeln('unknown --oracle value: $oracle');
    exit(2);
  }

  final work = Directory(workDir);
  if (!work.existsSync()) work.createSync(recursive: true);

  String? rardecodeBinary;
  if (useRardecode) {
    try {
      rardecodeBinary = _buildRardecodeOracle(work.path);
    } on Object catch (error) {
      stderr.writeln('FAIL: the rardecode oracle is mandatory and failed to build: $error');
      stderr.writeln(
        'install the Go toolchain (>= 1.21) and re-run; the module is pinned '
        'to github.com/nwaples/rardecode/v2@$rardecodePinnedVersion',
      );
      exit(1);
    }
  }

  var failures = 0;
  var compared = 0;
  for (final archivePath in archives) {
    final name = archivePath.split(Platform.pathSeparator).last;
    final Map<String, Uint8List> dartEntries;
    try {
      dartEntries = _decodeWithUnseal(archivePath);
    } on UnsealException catch (error) {
      if (allowReject) {
        stdout.writeln('reject $name (typed: ${error.message})');
        continue;
      }
      stderr.writeln('FAIL $name: Unseal rejects the archive typed: ${error.message}');
      failures++;
      continue;
    }
    Map<String, Uint8List>? rardecodeEntries;
    Map<String, Uint8List>? libarchiveEntries;
    try {
      rardecodeEntries = useRardecode
          ? _extractWithRardecode(rardecodeBinary!, archivePath, work.path)
          : null;
      libarchiveEntries = useLibarchive ? _extractWithBsdtar(bsdtar, archivePath, work.path) : null;
    } on StateError catch (error) {
      if (allowReject) {
        stdout.writeln('reject $name (oracle failed: ${error.message.split('\n').first})');
        continue;
      }
      stderr.writeln('FAIL $name: oracle extraction failed: ${error.message.split('\n').first}');
      failures++;
      continue;
    }

    // Filesystems may normalize extracted names (macOS writes NFD
    // while the archive stores NFC), so entries pair by exact name
    // first and, for names missing on one side, by content digest.
    // Content must match byte-for-byte in every pairing.
    final names = <String>{
      ...dartEntries.keys,
      if (rardecodeEntries != null) ...rardecodeEntries.keys,
      if (libarchiveEntries != null) ...libarchiveEntries.keys,
    }.toList()..sort();

    for (final entryName in names) {
      compared++;
      final unseal =
          dartEntries[entryName] ??
          _pairByDigest(
            dartEntries.values,
            rardecodeEntries?[entryName],
            libarchiveEntries?[entryName],
          );
      var rardecode = rardecodeEntries?[entryName];
      if (useRardecode) {
        rardecode ??= _pairByDigest(rardecodeEntries!.values, unseal, null);
      }
      var libarchive = libarchiveEntries?[entryName];
      if (useLibarchive) {
        libarchive ??= _pairByDigest(libarchiveEntries!.values, unseal, null);
      }

      if (unseal == null) {
        if (allowReject) {
          compared--;
          stdout.writeln(
            'reject $name/$entryName (Unseal is outside its subset; '
            'the oracle produced it)',
          );
        } else {
          stderr.writeln('FAIL $name/$entryName: Unseal did not produce this entry');
          failures++;
        }
        continue;
      }
      var ok = true;
      final pairedByName =
          dartEntries.containsKey(entryName) &&
          (!useRardecode || rardecodeEntries!.containsKey(entryName)) &&
          (!useLibarchive || libarchiveEntries!.containsKey(entryName));
      // After the null check above, Unseal's bytes are always present
      // here; the oracle sides are checked for presence below.
      if (useRardecode) {
        if (rardecode == null) {
          stderr.writeln('FAIL $name/$entryName: rardecode did not extract it');
          ok = false;
        } else if (!_sameBytes(unseal, rardecode)) {
          stderr.writeln(
            'FAIL $name/$entryName: ${unseal.length} bytes from Unseal vs '
            '${rardecode.length} from rardecode differ',
          );
          ok = false;
        }
      }
      if (useLibarchive) {
        if (libarchive == null) {
          stderr.writeln('FAIL $name/$entryName: bsdtar did not extract it');
          ok = false;
        } else if (!_sameBytes(unseal, libarchive)) {
          stderr.writeln(
            'FAIL $name/$entryName: ${unseal.length} bytes from Unseal vs '
            '${libarchive.length} from bsdtar differ',
          );
          ok = false;
        }
      }
      if (ok) {
        stdout.writeln(
          "ok   $name/$entryName (${unseal.length} bytes, "
          "${useRardecode && useLibarchive ? 'both oracles' : 'oracle'}"
          "${pairedByName ? '' : ', name paired by content'})",
        );
      } else {
        failures++;
      }
    }
  }

  if (failures > 0) {
    stderr.writeln('FAILED: $failures of $compared entries diverge');
    exit(1);
  }
  stdout.writeln('PASS: $compared entries byte-identical across decoders');
}

/// Finds an entry with exactly [reference]'s content when the name
/// itself is missing (filesystem name normalization), tolerating the
/// reference being null by matching against [also].
Uint8List? _pairByDigest(
  final Iterable<Uint8List> candidates,
  final Uint8List? reference,
  final Uint8List? also,
) {
  final target = reference ?? also;
  if (target == null) return null;
  final matches = candidates.where((final bytes) => _sameBytes(bytes, target)).toList();

  return matches.length == 1 ? matches.single : null;
}

bool _sameBytes(final Uint8List a, final Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }

  return true;
}

/// Decodes every file entry with Unseal's shared RAR 5 reader.
Map<String, Uint8List> _decodeWithUnseal(final String path) {
  final bytes = Uint8List.fromList(File(path).readAsBytesSync());
  final source = MemoryZipByteSource(bytes);
  final container = readRar5Structure(source);
  final entries = <String, Uint8List>{};
  for (final header in container.entries) {
    if (header.isDirectory) continue;
    final reason = header.unsupportedReason(
      archiveSolid: container.archiveSolid,
      sourceLength: bytes.length,
    );
    if (reason != null) {
      stderr.writeln('note: Unseal rejects "${header.name}": $reason');
      continue;
    }
    if (header.isStored) {
      entries[header.name] = Uint8List.sublistView(
        bytes,
        header.dataStart,
        header.dataStart + header.packedSize,
      );
      continue;
    }
    final packed = source.read(header.dataStart, header.packedSize);
    final decoded = decodeRar5Stream(
      packed: packed,
      uncompressedSize: header.unpackedSize,
      windowSize: header.dictSize,
    );
    if (header.hasDataCrc && getCrc32(decoded) != header.dataCrc32) {
      throw StateError('CRC-32 mismatch decoding "${header.name}"');
    }
    entries[header.name] = decoded;
  }

  return entries;
}

const String rardecodePinnedVersion = 'v2.0.0-20261013091751-ad22ba91a2ab';

/// Builds the pinned rardecode extractor once into [workDir]; returns
/// the binary path.
String _buildRardecodeOracle(final String workDir) {
  final binary = File('$workDir/rardecode-oracle').absolute.path;
  if (File(binary).existsSync()) return binary;

  final module = Directory('$workDir/go-module').absolute.path;
  if (!Directory(module).existsSync()) Directory(module).createSync(recursive: true);
  File('$module/go.mod').writeAsStringSync('''
module rardecodeoracle

go 1.21

require github.com/nwaples/rardecode/v2 $rardecodePinnedVersion
''');
  File('$module/main.go').writeAsStringSync(_rardecodeOracleSource);
  _run('go', ['mod', 'tidy'], workingDirectory: module);
  _run('go', ['build', '-o', binary, '.'], workingDirectory: module);

  if (!File(binary).existsSync()) {
    throw StateError('go build produced no binary');
  }

  return binary;
}

Map<String, Uint8List> _extractWithRardecode(
  final String binary,
  final String archivePath,
  final String workDir,
) {
  final outDir = '$workDir/rardecode-out';
  final output = Directory(outDir);
  if (output.existsSync()) output.deleteSync(recursive: true);
  output.createSync(recursive: true);
  _run(binary, [archivePath, outDir]);

  return _collectFiles(outDir);
}

Map<String, Uint8List> _extractWithBsdtar(
  final String bsdtar,
  final String archivePath,
  final String workDir,
) {
  final outDir = '$workDir/libarchive-out';
  final output = Directory(outDir);
  if (output.existsSync()) output.deleteSync(recursive: true);
  output.createSync(recursive: true);
  _run(bsdtar, ['-x', '-f', File(archivePath).absolute.path, '-C', outDir]);

  return _collectFiles(outDir);
}

Map<String, Uint8List> _collectFiles(final String dirPath) {
  final entries = <String, Uint8List>{};
  final dir = Directory(dirPath);
  for (final entity in dir.listSync(recursive: true)) {
    if (entity is! File) continue;
    final relative = entity.path.substring(dirPath.length + 1).replaceAll('\\', '/');
    entries[relative] = Uint8List.fromList(entity.readAsBytesSync());
  }

  return entries;
}

void _run(final String executable, final List<String> arguments, {final String? workingDirectory}) {
  final result = Process.runSync(
    executable,
    arguments,
    workingDirectory: workingDirectory,
    stdoutEncoding: convert.utf8,
    stderrEncoding: convert.utf8,
  );
  if (result.exitCode != 0) {
    throw StateError(
      '$executable ${arguments.join(' ')} failed (${result.exitCode}):\n'
      '${result.stdout}\n${result.stderr}',
    );
  }
}

const String _rardecodeOracleSource = '''
// Command rardecode-oracle extracts every file entry of a RAR archive
// into a directory for byte-for-byte oracle comparison. Generated by
// Unseal's tool/rar5_compare.dart and pinned to the rardecode revision
// the RAR 5 port is based on.
package main

import (
	"fmt"
	"io"
	"os"
	"path/filepath"

	rardecode "github.com/nwaples/rardecode/v2"
)

func main() {
	if len(os.Args) != 3 {
		fmt.Fprintln(os.Stderr, "usage: rardecode-oracle <archive.rar> <outdir>")
		os.Exit(2)
	}
	f, err := os.Open(os.Args[1])
	if err != nil {
		fmt.Fprintln(os.Stderr, "open:", err)
		os.Exit(1)
	}
	defer f.Close()

	r, err := rardecode.NewReader(f)
	if err != nil {
		fmt.Fprintln(os.Stderr, "reader:", err)
		os.Exit(1)
	}
	for {
		hdr, err := r.Next()
		if err == io.EOF {
			return
		}
		if err != nil {
			fmt.Fprintln(os.Stderr, "next:", err)
			os.Exit(1)
		}
		if hdr.IsDir {
			continue
		}
		name := filepath.Join(os.Args[2], filepath.FromSlash(hdr.Name))
		if err := os.MkdirAll(filepath.Dir(name), 0o755); err != nil {
			fmt.Fprintln(os.Stderr, "mkdir:", err)
			os.Exit(1)
		}
		out, err := os.Create(name)
		if err != nil {
			fmt.Fprintln(os.Stderr, "create:", err)
			os.Exit(1)
		}
		if _, err := io.Copy(out, r); err != nil {
			out.Close()
			fmt.Fprintln(os.Stderr, "copy:", hdr.Name, err)
			os.Exit(1)
		}
		out.Close()
	}
}
''';
