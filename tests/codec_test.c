#include <libheif/heif.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define WIDTH 64
#define HEIGHT 64

/* Builds an RGB test image with a diagonal gradient so chroma downsampling
 * (in particular the SharpYUV path) has non-flat input to operate on. */
static heif_image* make_test_image(void) {
  heif_image* image = NULL;
  heif_error err = heif_image_create(WIDTH, HEIGHT, heif_colorspace_RGB, heif_chroma_interleaved_RGB, &image);
  if (err.code != heif_error_Ok) {
    fprintf(stderr, "heif_image_create failed: %s\n", err.message);
    return NULL;
  }

  err = heif_image_add_plane(image, heif_channel_interleaved, WIDTH, HEIGHT, 8);
  if (err.code != heif_error_Ok) {
    fprintf(stderr, "heif_image_add_plane failed: %s\n", err.message);
    heif_image_release(image);
    return NULL;
  }

  size_t stride = 0;
  uint8_t* data = heif_image_get_plane2(image, heif_channel_interleaved, &stride);
  for (int y = 0; y < HEIGHT; y++) {
    for (int x = 0; x < WIDTH; x++) {
      uint8_t* px = data + (size_t)y * stride + (size_t)x * 3;
      px[0] = (uint8_t)(x * 255 / (WIDTH - 1));
      px[1] = (uint8_t)(y * 255 / (HEIGHT - 1));
      px[2] = (uint8_t)((x + y) * 255 / (WIDTH + HEIGHT - 2));
    }
  }

  return image;
}

/* Encodes 'image' with the encoder registered for 'format', optionally forcing
 * the SharpYUV chroma downsampling path, writes it to 'path', then decodes it
 * back and checks the dimensions round-trip. */
static int encode_and_roundtrip(heif_image* image, heif_compression_format format, const char* path,
                                 int use_sharp_yuv) {
  heif_context* enc_ctx = heif_context_alloc();

  heif_encoder* encoder = NULL;
  heif_error err = heif_context_get_encoder_for_format(enc_ctx, format, &encoder);
  if (err.code != heif_error_Ok) {
    fprintf(stderr, "%s: no encoder for format: %s\n", path, err.message);
    heif_context_free(enc_ctx);
    return 1;
  }
  printf("%s: encoder=%s\n", path, heif_encoder_get_name(encoder));

  heif_encoding_options* options = heif_encoding_options_alloc();
  if (use_sharp_yuv) {
    options->color_conversion_options.preferred_chroma_downsampling_algorithm = heif_chroma_downsampling_sharp_yuv;
    options->color_conversion_options.only_use_preferred_chroma_algorithm = 1;
  }

  err = heif_context_encode_image(enc_ctx, image, encoder, options, NULL);
  heif_encoding_options_free(options);
  heif_encoder_release(encoder);
  if (err.code != heif_error_Ok) {
    fprintf(stderr, "%s: encode failed: %s\n", path, err.message);
    heif_context_free(enc_ctx);
    return 1;
  }

  err = heif_context_write_to_file(enc_ctx, path);
  heif_context_free(enc_ctx);
  if (err.code != heif_error_Ok) {
    fprintf(stderr, "%s: write failed: %s\n", path, err.message);
    return 1;
  }

  heif_context* dec_ctx = heif_context_alloc();
  err = heif_context_read_from_file(dec_ctx, path, NULL);
  if (err.code != heif_error_Ok) {
    fprintf(stderr, "%s: re-read failed: %s\n", path, err.message);
    heif_context_free(dec_ctx);
    return 1;
  }

  heif_image_handle* handle = NULL;
  err = heif_context_get_primary_image_handle(dec_ctx, &handle);
  if (err.code != heif_error_Ok) {
    fprintf(stderr, "%s: get_primary_image_handle failed: %s\n", path, err.message);
    heif_context_free(dec_ctx);
    return 1;
  }

  int width = heif_image_handle_get_width(handle);
  int height = heif_image_handle_get_height(handle);
  int ok = width == WIDTH && height == HEIGHT;
  printf("%s: roundtrip %dx%d %s\n", path, width, height, ok ? "OK" : "FAIL");

  heif_image_handle_release(handle);
  heif_context_free(dec_ctx);
  return ok ? 0 : 1;
}

/* Decodes 'path' (expected to be an AV1 file) once with the default decoder and
 * once explicitly with the aom decoder plugin, so both AV1 decode paths are exercised. */
static int decode_with_decoder_id(const char* path, const char* decoder_id) {
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

  heif_decoding_options* options = heif_decoding_options_alloc();
  options->decoder_id = decoder_id;

  heif_image* image = NULL;
  err = heif_decode_image(handle, &image, heif_colorspace_RGB, heif_chroma_interleaved_RGB, options);
  heif_decoding_options_free(options);
  int ok = err.code == heif_error_Ok;
  printf("%s: decode with decoder_id=%s %s\n", path, decoder_id, ok ? "OK" : "FAIL");
  if (ok) {
    heif_image_release(image);
  } else {
    fprintf(stderr, "%s: decode failed: %s\n", path, err.message);
  }

  heif_image_handle_release(handle);
  heif_context_free(ctx);
  return ok ? 0 : 1;
}

int main(int argc, char** argv) {
  if (argc != 2) {
    fprintf(stderr, "usage: %s <tmp-dir>\n", argv[0]);
    return 2;
  }
  const char* tmp_dir = argv[1];

  heif_image* image = make_test_image();
  if (image == NULL) {
    return 1;
  }

  int fail = 0;

  char hevc_path[4096];
  snprintf(hevc_path, sizeof(hevc_path), "%s/codec_test_x265.heic", tmp_dir);
  fail |= encode_and_roundtrip(image, heif_compression_HEVC, hevc_path, 0);

  char av1_path[4096];
  snprintf(av1_path, sizeof(av1_path), "%s/codec_test_aom.avif", tmp_dir);
  fail |= encode_and_roundtrip(image, heif_compression_AV1, av1_path, 0);

  char sharp_path[4096];
  snprintf(sharp_path, sizeof(sharp_path), "%s/codec_test_sharpyuv.heic", tmp_dir);
  fail |= encode_and_roundtrip(image, heif_compression_HEVC, sharp_path, 1);

  fail |= decode_with_decoder_id(av1_path, "dav1d");
  fail |= decode_with_decoder_id(av1_path, "aom");

  heif_image_release(image);

  return fail ? 1 : 0;
}
