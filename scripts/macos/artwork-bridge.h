// Test driver uses the same C ABI as Tauri's Rust host.
void aonsoku_artwork_initialize(const char *root, const char *license);
char *aonsoku_artwork_call(const char *request);
void aonsoku_artwork_free(char *result);
