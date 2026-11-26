#include "VoiceBridge.h"
#include "sherpa.h"
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
static void *voice_engine_config(const char *dir, int32_t search_paths) {
  char enc[PATH_MAX], dec[PATH_MAX], join[PATH_MAX], tok[PATH_MAX];
#define PART(dst, file)                                                        \
  if (snprintf(dst, sizeof(dst), "%s/%s", dir, file) >= (int)sizeof(dst) ||    \
      access(dst, R_OK))                                                       \
    return NULL;
  PART(enc, "encoder.onnx");
  PART(dec, "decoder.onnx");
  PART(join, "joiner.onnx");
  PART(tok, "tokens.txt");
  SherpaOnnxOnlineRecognizerConfig c = {0};
  c.feat_config.sample_rate = 16000;
  c.feat_config.feature_dim = 80;
  c.model_config.transducer.encoder = enc;
  c.model_config.transducer.decoder = dec;
  c.model_config.transducer.joiner = join;
  c.model_config.tokens = tok;
  c.hotwords_score = 1.25f;
  c.model_config.num_threads = 2;
  c.model_config.provider = "cpu";
  c.model_config.model_type = "zipformer2";
  c.decoding_method = "modified_beam_search";
  c.max_active_paths = search_paths;
  c.enable_endpoint = 1;
  c.rule1_min_trailing_silence = 2.4f;
  // File replay can wait for a longer pause before closing a phrase.
  c.rule2_min_trailing_silence = search_paths > 4 ? 1.6f : 0.95f;
  c.rule3_min_utterance_length = 22.f;
  return (void *)SherpaOnnxCreateOnlineRecognizer(&c);
}
void *voice_engine(const char *dir) { return voice_engine_config(dir, 4); }
void *voice_engine_deep(const char *dir) { return voice_engine_config(dir, 12); }
void voice_engine_release(void *e) {
  if (e)
    SherpaOnnxDestroyOnlineRecognizer(e);
}
void *voice_stream(void *e) {
  return e ? (void *)SherpaOnnxCreateOnlineStream(e) : NULL;
}
void *voice_context_stream(void *e, const char *words) {
  return (e && words && *words) ? (void *)SherpaOnnxCreateOnlineStreamWithHotwords(e, words) : voice_stream(e);
}
void voice_stream_release(void *s) {
  if (s)
    SherpaOnnxDestroyOnlineStream(s);
}
static void decode(void *e, void *s) {
  while (SherpaOnnxIsOnlineStreamReady(e, s))
    SherpaOnnxDecodeOnlineStream(e, s);
}
void voice_feed(void *e, void *s, const float *p, int32_t n) {
  if (n > 0) {
    SherpaOnnxOnlineStreamAcceptWaveform(s, 16000, p, n);
    decode(e, s);
  }
}
char *voice_text(void *e, void *s) {
  const SherpaOnnxOnlineRecognizerResult *r =
      SherpaOnnxGetOnlineStreamResult(e, s);
  char *p = strdup(r && r->text ? r->text : "");
  if (r)
    SherpaOnnxDestroyOnlineRecognizerResult(r);
  return p;
}
// Crop *tokens* to the central time interval, while the acoustic model sees both margins.
// Without timestamps a clipped window is not valid independent evidence at the seam.
char *voice_text_window(void *e, void *s, float begin, float end) {
  const SherpaOnnxOnlineRecognizerResult *r = SherpaOnnxGetOnlineStreamResult(e, s);
  if (!r) return NULL;
  char *out = NULL;
  if (r->timestamps && r->tokens_arr && r->count > 0) {
    size_t bytes = 1;
    for (int i=0; i<r->count; ++i) if (r->tokens_arr[i]) bytes += strlen(r->tokens_arr[i]);
    out = calloc(bytes, 1);
    if (out) { size_t pos=0; for (int i=0; i<r->count; ++i) {
      const char *t=r->tokens_arr[i]; if (!t || r->timestamps[i] < begin || r->timestamps[i] >= end) continue;
      size_t n=strlen(t); memcpy(out+pos,t,n); pos+=n;
    } }
  } else if (begin <= 0 && end > 1e8f && r->text) { out=strdup(r->text); }
  SherpaOnnxDestroyOnlineRecognizerResult(r); return out;
}
void voice_text_release(char *s) { free(s); }
int voice_endpoint(void *e, void *s) {
  return SherpaOnnxOnlineStreamIsEndpoint(e, s);
}
void voice_reset(void *e, void *s) { SherpaOnnxOnlineStreamReset(e, s); }
void voice_end(void *e, void *s, int32_t pad_samples) {
  // This is decoder lookahead, not capture time; it is never written to the recording.
  static const float silence[16000] = {0};
  while (pad_samples > 0) {
    int32_t n = pad_samples < 16000 ? pad_samples : 16000;
    SherpaOnnxOnlineStreamAcceptWaveform(s, 16000, silence, n);
    pad_samples -= n;
  }
  SherpaOnnxOnlineStreamInputFinished(s);
  decode(e, s);
}
