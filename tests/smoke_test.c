#include <libheif/heif.h>
#include <stdio.h>
#include <stdlib.h>

/* Decodes a single HEIF/AVIF file through the statically linked libheif and
 * checks its reported alpha channel against the expectation passed on the
 * command line, to exercise the HEVC (libde265/x265) and AV1 (dav1d/libaom)
 * codec plugins as well as the libsharpyuv color-conversion path. */
int main(int argc, char** argv) {
  if (argc != 3) {
    fprintf(stderr, "usage: %s <file> <expect-alpha:0|1>\n", argv[0]);
    return 2;
  }

  const char* path = argv[1];
  int expect_alpha = atoi(argv[2]);

  heif_context* ctx = heif_context_alloc();
  heif_error err = heif_context_read_from_file(ctx, path, NULL);
  if (err.code != heif_error_Ok) {
    fprintf(stderr, "%s: read failed: %s\n", path, err.message);
    heif_context_free(ctx);
    return 1;
  }

  heif_image_handle* handle = NULL;
  err = heif_context_get_primary_image_handle(ctx, &handle);
  if (err.code != heif_error_Ok) {
    fprintf(stderr, "%s: get_primary_image_handle failed: %s\n", path, err.message);
    heif_context_free(ctx);
    return 1;
  }

  int width = heif_image_handle_get_width(handle);
  int height = heif_image_handle_get_height(handle);
  int has_alpha = heif_image_handle_has_alpha_channel(handle);

  heif_image* image = NULL;
  err = heif_decode_image(handle, &image, heif_colorspace_RGB, heif_chroma_interleaved_RGB, NULL);
  if (err.code != heif_error_Ok) {
    fprintf(stderr, "%s: decode failed: %s\n", path, err.message);
    heif_image_handle_release(handle);
    heif_context_free(ctx);
    return 1;
  }

  int ok = width > 0 && height > 0 && has_alpha == expect_alpha;
  printf("%s: %dx%d alpha=%d %s\n", path, width, height, has_alpha, ok ? "OK" : "FAIL");

  heif_image_release(image);
  heif_image_handle_release(handle);
  heif_context_free(ctx);

  return ok ? 0 : 1;
}
