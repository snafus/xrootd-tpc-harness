# Multi-stream HTTP-TPC pull: test harness

Tests and measurements for the pull mode of XRootD HTTP third-party copy when
the client asks for several streams (`X-Number-Of-Streams`). They are kept in a
repository of their own, apart from the XRootD source: they need a source that
misbehaves on demand and, for the measurements, a privileged container, and
changes to XRootD itself should stay small and easy to review.

The harness needs nothing from the XRootD source tree. It tests the `xrootd`
found on the PATH, built or installed, and needs bash, bats 1.11 or later,
python3, curl and getfattr.

## Contents

| File | Purpose |
|------|---------|
| `faulty_source.py` | HTTP source that serves synthetic files of any size and injects faults chosen in the URL (dropped connection, 5xx, ignored `Range`, wrong or short range, corrupted data, stall, redirect, ...). Run it with `--help` for the list. |
| `dst.cfg` | Destination XRootD: plain HTTP, no authentication, files on local disk. |
| `dst-cksrt.cfg` | The same, with real-time checksums on (`ofs.cksrt auto on`). |
| `lib.bash` | Start and stop the servers of a test. |
| `helper.bash` | Shared test functions: start the two servers, run a pull, compare the destination file with what the source serves. |
| `matrix.bats` | A pull must give the right file for every size and stream count. |
| `faults.bats` | What a pull does when the source misbehaves. |
| `ordering.bats` | A pull must give the right file whatever the order in which the ranges arrive, and when one stream is slow. |
| `checksum.bats` | The checksum XRootD computes while the file is written: stored at the end of a pull, and different from the source's when the source sent wrong data. |
| `run.sh` | Runs the quick or the full suite and compares the failures with `known-failures.txt`. |
| `known-failures.txt` | Tests that fail today because of a known defect. |
| `bdp/measure.sh` | Throughput of a pull over an emulated long path (delay and rate limit), by number of streams. |
| `docker/` | AlmaLinux 9 build and test container, and `dev.sh` to drive it. |

## Running

Against an installed XRootD, or one already on the PATH:

```
./run.sh            # quick suite
./run.sh full       # full suite
bats faults.bats    # one file
```

In the development container (AlmaLinux 9), which also builds XRootD. Write the
path of the XRootD source tree in `local.env` first (`XROOTD_SRC=/path/to/xrootd`):

```
docker/dev.sh image        # once
docker/dev.sh configure    # once
docker/dev.sh build

docker/dev.sh test          # quick suite
docker/dev.sh test full     # full suite

# one file, or one test
docker/dev.sh bats faults.bats
docker/dev.sh bats -f "one 503" faults.bats

# throughput over an emulated long path (needs a privileged container)
DOCKER_ARGS="--privileged -u 0" docker/dev.sh run bdp/measure.sh /path/to/results.tsv
```

## Settings

| Setting | Meaning |
|---------|---------|
| `XROOTD_BUILD` | An XRootD build tree. Its programs are used; `run.sh` also runs its TPC unit tests and, in full mode, its own TPC tests. `docker/dev.sh` sets it to `$XROOTD_SRC/build`. |
| `XROOTD_SRC` | An XRootD source tree. Used by `docker/dev.sh` to build, and for the bats it carries in `vendor/`. |
| `BATS` | The bats program to use. |
| `TPC_DEST_DIR` | Directory in which the destination server keeps its files. Set it to test another storage, for example a CephFS mount. Each test makes its own directory there and removes it. |
| `TPC_SURVEY` | A file to which every pull appends one line: its outcome, whether the destination file is correct, the time taken, and how many requests and connections the source saw. |
| `BATS_SKIP_SERVER_LOGS` | Set it to leave the server logs out of the report of a failed test. |

Settings can also be written in the file `local.env`, which is not committed.

## Three levels

| Level | When | Contents |
|-------|------|----------|
| Quick (about 30 s) | After every change | Unit tests, when a build tree is given; pulls of files up to 48 MiB with 1 and 4 streams; every fault test that needs no waiting; three ordering tests; the checksum tests. |
| Full (about 4 minutes) | Before a commit | The quick suite, plus the tests tagged `slow` (2 and 10 streams, 256 MiB and 1 GiB files, faults that involve a timeout, more ordering seeds, a slow connection, the run-ahead limit) and the upstream TPC tests. |
| Measurement | On demand | `bdp/measure.sh`. It gives numbers, not a pass or fail, and takes from several minutes to an hour. |

A test belongs to the full suite only if it is tagged: `# bats test_tags=slow`
above an `@test`, or `--tags slow` for a generated test. Tag a test when it
takes more than about two seconds.

Some tests fail today because of defects that are not fixed yet. They are
listed in `known-failures.txt`, and `run.sh` succeeds when exactly those tests
fail. A new failure is reported as an error. So is a listed test that now
passes: the commit that fixes a defect removes its lines from the list.

## What the tests assert

Every pull must end with a verdict (`success:` or `failure:`), must never
report success for a file that differs from the source, and must leave the
destination server running. Tests whose name starts with "survives" also
expect the pull to succeed despite the fault.
