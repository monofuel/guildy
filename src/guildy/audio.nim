## Lightweight PCM resamplers and channel converters.
## Used to bridge between Discord voice (48kHz stereo) and
## OpenAI Realtime (24kHz mono).

proc stereoToMono*(input: openArray[int16]): seq[int16] =
  ## Mix interleaved stereo PCM16 down to mono by averaging channels.
  ## `input.len` must be even.
  result = newSeq[int16](input.len div 2)
  var i = 0
  var j = 0
  while i + 1 < input.len:
    result[j] = int16((int32(input[i]) + int32(input[i+1])) div 2)
    inc j
    i += 2

proc monoToStereo*(input: openArray[int16]): seq[int16] =
  ## Duplicate mono PCM16 to interleaved stereo.
  result = newSeq[int16](input.len * 2)
  for i in 0 ..< input.len:
    result[i*2] = input[i]
    result[i*2 + 1] = input[i]

proc downsample2x*(input: openArray[int16]): seq[int16] =
  ## Decimate mono PCM16 by 2 using simple 2-tap averaging
  ## to dampen aliasing.
  result = newSeq[int16](input.len div 2)
  var i = 0
  var j = 0
  while i + 1 < input.len:
    result[j] = int16((int32(input[i]) + int32(input[i+1])) div 2)
    inc j
    i += 2

proc upsample2x*(input: openArray[int16]): seq[int16] =
  ## Linearly interpolate mono PCM16 to double the sample rate.
  result = newSeq[int16](input.len * 2)
  for i in 0 ..< input.len:
    result[i*2] = input[i]
    let nextSample = if i + 1 < input.len: input[i+1] else: input[i]
    result[i*2 + 1] = int16((int32(input[i]) + int32(nextSample)) div 2)

proc discord48kStereoTo24kMono*(input: openArray[int16]): seq[int16] =
  ## Convert a 48kHz stereo PCM16 frame to 24kHz mono.
  ## Order: stereo->mono mix, then decimate by 2.
  result = downsample2x(stereoToMono(input))

proc openai24kMonoTo48kStereo*(input: openArray[int16]): seq[int16] =
  ## Convert a 24kHz mono PCM16 frame to 48kHz stereo.
  ## Order: upsample by 2, then duplicate to stereo.
  result = monoToStereo(upsample2x(input))
