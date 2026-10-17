# Path to Rust-built FFI lib
PLIST_LIB := "target/debug/libplist.dylib"

# Add -ldl if you get dynamic loading errors on Linux
CFLAGS := "-Iinclude -Ilibcnary/include -Wall -Wextra"
LDFLAGS := "-Ltarget/debug -lplist_ffi"

# List of C test programs
TEST_BINS := "plist_test plist_cmp integer_set plist_btest plist_jtest"

# Build all test binaries
default:
    @just build-tests
    @just test

# Build C test programs
build-tests:
    for src in {{TEST_BINS}}; do \
        echo "Compiling $src.c..."; \
        cc test/$src.c {{CFLAGS}} {{LDFLAGS}} -o test/$src; \
    done

build-plistutil:
    cc tools/plistutil.c {{CFLAGS}} {{LDFLAGS}} -o tools/plistutil

# Run .test files
test:
    @echo "Running .test scripts..."
    cd test && for f in *.test; do \
        echo "--- Running $f ---"; \
        env RUST_BACKTRACE=1 top_srcdir=.. top_builddir=.. bash ./$f || echo "❌ Failed: $f"; \
    done

# Clean build output
clean:
    rm -rf build

