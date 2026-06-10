/* Build-time LeakSanitizer switch, linked by mayhem/build.sh into every executable of both of its
 * builds: the two ASan-instrumented fuzz targets (/mayhem/wla-z80, /mayhem/wla-6502) and every
 * test-build wla-* assembler and wlalink (build-tests/binaries/, run by mayhem/test.sh).
 *
 * -fsanitize=address always bundles LeakSanitizer and no compiler flag keeps ASan while dropping only
 * leak detection. The wla-* assemblers are arena-by-exit: they allocate global/parse buffers and, on
 * many error paths, exit without freeing them, so an at-exit leak check would report benign "leaks" on
 * a large fraction of inputs. Leaks are not the defect class this environment fuzzes for, so the LSan
 * runtime is told it is turned off. AddressSanitizer's memory-error checks and every UBSan check stay
 * on and halting. No runtime sanitizer option is set anywhere. */
int __lsan_is_turned_off(void) { return 1; }
