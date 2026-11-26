#ifndef VOICEBRIDGE_H
#define VOICEBRIDGE_H
#include <stdint.h>
void *voice_engine(const char *directory);
void *voice_engine_deep(const char *directory);
void voice_engine_release(void *engine);
void *voice_stream(void *engine);
void *voice_context_stream(void *engine, const char *words);
void voice_stream_release(void *stream);
void voice_feed(void *engine, void *stream, const float *samples,
                int32_t count);
char *voice_text(void *engine, void *stream);
char *voice_text_window(void *engine, void *stream, float begin, float end);
void voice_text_release(char *text);
int voice_endpoint(void *engine, void *stream);
void voice_reset(void *engine, void *stream);
void voice_end(void *engine, void *stream, int32_t pad_samples);
#endif
