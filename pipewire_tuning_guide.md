# Tuning PipeWire

This is a quick and dirty guide to low-latency, high-fidelity audio via PipeWire in Linux. It's really just notes based on my recent research into how to get the most out of PipeWire (v1.4.7) for my use case, but it's working fantastically for me and it may help you get pointed in the right direction.

## Basic Linux Tuning

It's really desirable to be running a kernel with RT support, e.g. Xanmod, Liquorix, zen, or an 'RT' patched kernel. To get the most out of this, we're also going to need to give our audio user(s) permissions to run in realtime.

Create something like `/etc/security/limits.d/99-audio.conf` if it doesn't exist, and add:

```
#
# Realtime audio tuning, per JACK's recommendations
#

@audio   -  rtprio     95
@audio   -  memlock    unlimited
@audio   -  nice      -19
```
PipeWire currently only runs at `-11` by default, at least at present. If you ever want to use the PipeWire JACK plugin `pipewire-jack`, for JACK applications to output via PipeWire, allowing it to run at up to `-19` might be best. If not, `-11` is probably fine here.

Next, make sure any users who will use PipeWire are in the `audio` group, e.g.:

```
$ groups $USER
cdrom floppy sudo audio dip video plugdev power users netdev bluetooth lpadmin scanner gamemode
```
If the user in question is not in `audio`, add them:

```bash
sudo usermod -a -G audio $USER
```

## Determining Hardware Support 

First, we need to determine which sound card we're targeting. I used `aplay` to show me what was available for playback:

```
$ aplay -l

**** List of PLAYBACK Hardware Devices ****
card 0: DX [Xonar DX], device 0: Multichannel [Multichannel]
  Subdevices: 1/1
  Subdevice #0: subdevice #0
card 0: DX [Xonar DX], device 1: Digital [Digital]
  Subdevices: 1/1
  Subdevice #0: subdevice #0
card 1: HDMI [HDA ATI HDMI], device 3: HDMI 0 [MAG 325CQF]
  Subdevices: 1/1
  Subdevice #0: subdevice #0
card 1: HDMI [HDA ATI HDMI], device 7: HDMI 1 [HDMI 1]
  Subdevices: 1/1
  Subdevice #0: subdevice #0
card 1: HDMI [HDA ATI HDMI], device 8: HDMI 2 [HDMI 2]
  Subdevices: 1/1
  Subdevice #0: subdevice #0
card 1: HDMI [HDA ATI HDMI], device 9: HDMI 3 [HDMI 3]
  Subdevices: 1/1
  Subdevice #0: subdevice #0
```

*(If I'd wanted to list __recording__ devices, I could use `arecord -l` instead, but I'm focused on optimizing playback in this guide).* 

In my case, I'm using my discrete sound card for playback, which is enumerated as `card 0`, `device 0`. This would typically be exposed to the system as `/proc/asound/card0/stream0`, and this will be the case on the vast majority of sound cards in Linux. Grabbing the sample rates your card supports in hardware is really easy using this interface:

```
$ cat /proc/asound/card0/stream0 | grep Rates

    Rates: 44100, 48000, 96000, 192000
    Rates: 44100, 48000, 96000, 192000
    Rates: 44100, 48000, 96000, 192000
    Rates: 44100, 48000, 96000, 192000
    Rates: 44100, 48000, 96000, 192000
    Rates: 44100, 48000, 96000, 192000
    Rates: 44100, 48000, 96000, 192000
    Rates: 44100, 48000, 96000, 192000
```

We can see that this particular card supports 44.1k, 48k, 96k, and 192k.

However, I have a weird card, and it doesn't use this straightforward convention. So I had to use a different method (which should also work with any supported card out there):

```
$ aplay -D hw:0,0 --dump-hw-params test.wav

HW Params of device "hw:0,0":
--------------------
ACCESS:  MMAP_INTERLEAVED RW_INTERLEAVED
FORMAT:  S16_LE S32_LE
SUBFORMAT:  STD MSBITS_MAX
SAMPLE_BITS: [16 32]
FRAME_BITS: [32 256]
CHANNELS: [2 8]
RATE: [32000 192000]
PERIOD_TIME: (10 8192000]
PERIOD_SIZE: [2 262144]
PERIOD_BYTES: [64 8388608]
PERIODS: [1 131072]
BUFFER_TIME: (10 8192000]
BUFFER_SIZE: [2 262144]
BUFFER_BYTES: [64 1048576]
TICK_TIME: ALL
--------------------
aplay: set_params:1387: Sample format non available
Available formats:
- S16_LE
- S32_LE
```

In this case, I'm just playing a null WAV file I made with `sox`, but it could be literally any sound file that's supported by `aplay`. We only care about the hardware dump output, which tells us: `RATE: [32000 192000]`; this is a range, not a series like the other card. That means the card supports a floor and a ceiling in hardware, and everything in between, so we can use any rates in that range natively. Nice.

## Setting Up WirePlumber

WirePlumber is the modular session / policy manager for PipeWire.

Running the latest version of `wireplumber` that's readily available to us is a good idea, so we can get all the latest bug fixes and optimizations. In my case, I'm running `Debian 13` aka "Trixie", so I'd do:

```bash
sudo apt -t trixie-backports install wireplumber
```

### Configuring a WirePlumber Lua
Now that we know what range or series of sample rates our card supports natively, we can apply it to WirePlumber. Create `~/.config/wireplumber/main.lua.d/` if it doesn't already exist (it didn't for me):

```bash
mkdir -p ~/.config/wireplumber/main.lua.d/
```

Then add `~/.config/wireplumber/main.lua.d/50-alsa-rate.lua` with a few stanzas like the following:

```
alsa_monitor.rules = {
  {
    matches = {
      {
        { "node.name", "matches", "alsa_output.*" },
      },
    },
    apply_properties = {
      ["audio.rate"] = 48000,
      ["audio.allowed-rates"] = { 44100, 48000, 96000, 176400, 192000 },
      ["api.alsa.period-size"] = 128,
      ["api.alsa.headroom"] = 0,
      ["resample.quality"] = 14,
    },
  },
}
```
The `["audio.rate"]` is going to be our standard sample rate. For my needs (mostly games, music, YT and similar), 48kHz is my sweet spot. It's *probably* yours, too.

`["audio.allowed-rates"]` are what we want to advertise to the system as supported. I chose these because they're standard sample rates and my card supports them without resampling. On the other card I looked at earlier, it only supported a series of sample rates that didn't include `176400`, so I'd not have set that rate for that particular card. As my card allows a range from `32000 - 192000`, I'm all good for any arbitrary sample rates.

Note that while I *could* include 32k, this is generally not recommended, as the sample rate isn't commonly encountered outside of VoIP, and it's better to just let the system resample in software for sample rates that low.

`["resample.quality"]` is a range of `0 - 14` with `0` essentially being "linear" and `14` being the maximum quality. A value of `10` is generally considered the sweet spot for modern hardware, `4` being a good middle ground for constrained or embedded systems, and `14` being uncompromising. Ideally we're playing sample rates that are supported directly by our hardware and our configuration, and no resampling will even be necessary.

## Setting Up PipeWire

Even more so than WirePlumber, having the latest version of `pipewire` that's within arm's reach is a really good idea. E.g.:

```bash
sudo apt install -t trixie-backports pipewire pipewire-audio pipewire-alsa pipewire-pulse pipewire-jack
```
And make sure `pulseaudio` is disabled and masked out:

```bash
sudo apt purge pulseaudio pulseaudio-utils
sudo apt autoremove
systemctl --user mask pulseaudio
```

### Buffers
Now we need to set up PipeWire itself. Create the local config directory, if it doesn't already exist:

```bash
mkdir -p ~/.config/pipewire/pipewire.conf.d/
```

Compose `~/.config/pipewire/pipewire.conf.d/10-buffers.conf` with something like this:

```
context.properties = {
    default.clock.min-quantum = 32
    default.clock.max-quantum = 1024
    default.clock.quantum = 256
    default.clock.rate = 48000
}
```
Our quantums are our variable buffer size. Too small and we may have underruns if the card's too low-end, our system is too busy or too weak, etc. Too big and we'll cause unnecessary audio latency. These settings are great for my fairly humble system, at least by modern standards:

 - Ryzen 7 3700X @4.63GHz (-48mV)
 - 32GB DDR4 3200 (XMP)
 - ASUS Xonar DX (C-Media Electronics Inc CMI8788 [Oxygen HD Audio])
 - Latest [Xanmod](https://xanmod.org/) kernel

Despite the somewhat modest and outdated hardware, I haven't had any cut-outs, clicks, distortion, or any other sound issues even when playing multiple audio streams at once under load. This includes heavy games like Mount & Blade II: Bannerlord, with hundreds of sounds playing simultaneously, and hundreds of units on the field. But, YMMV. Consider this a starting point. If you find that you can get away with smaller buffers or need larger ones, do what you need to do.

### Sample Rates

Here we're essentially mirroring what we already did for WirePlumber, but for PipeWire directly this time.

Create `~/.config/pipewire/pipewire.conf.d/20-sample-rate.conf` with something like the following:

```
context.properties = {
    default.clock.rate = 48000
    default.clock.allowed-rates = [ 44100 48000 88200 96000 176400 192000 ]
}
```
Same deal, a default clock rate and our list of allowed sample rates. 

## Applying Our Changes

Ideally, just restart the whole system. Fresh start, fewer variables. 

Otherwise, you can log out and back in again (necessary if you weren't previously in the `audio` group, for example), or restart `pipewire` locally, e.g.:

```bash
systemctl --user restart pipewire pipewire-pulse wireplumber
```

## Testing

In my case, I tested some 192kHz FLAC from [www.2L.no](https://www.2L.no/) via `mplayer`, for maximum verbiage:

```
Playing 2L-090C_stereo-192kHz_01.flac.
libavformat file format detected.
[lavf] stream 0: audio (flac), -aid 0
==========================================================================
Opening video decoder: [ffmpeg] FFmpeg's libavcodec codec family
Selected video codec: [ffmjpeg] vfm: ffmpeg (FFmpeg MJPEG)
==========================================================================
Clip info:
 COMPOSER: Pyotr Ilyich Tchaikovsky
 disc: 2
 PERFORMER: TrondheimSolistene
 TITLE: Tchaikovsky, SOUVENIR de Florence op. 70: I. Allegro con spirito
 DISCTOTAL: 2
 TRACKTOTAL: 5
 Album: SOUVENIR part II
 Artist: TrondheimSolistene
 Comment: 2L-090C made in Norway 2012 Lindberg Lyd AS (www.2L.no)
 Genre: Classical
 album_artist: TrondheimSolistene
 DATE: 2012
 track: 1
==========================================================================
Opening audio decoder: [ffmpeg] FFmpeg/libavcodec audio decoders
AUDIO: 192000 Hz, 2 ch, s32le, 0.0 kbit/0.00% (ratio: 0->1536000)
Selected audio codec: [ffflac] afm: ffmpeg (FFmpeg FLAC audio)
==========================================================================
AO: [alsa] 192000Hz 2ch s32le (4 bytes per sample)
Starting playback...
```

As you can see, the `AUDIO` rate is being output at 192kHz. Sounds amazing, and I can still stream basic 44.1kHz YT stuff or whatever, simultaneously. Excellent.

## Extras

Optionally, if you're not routinely playing MIDI from your desktop as a matter of course, you can disable `fluidsynth` sessions, which can free up resources and avoid potential conflicts.

```bash
systemctl --user stop fluidsynth
systemctl --user mask fluidsynth
```
Personally I prefer `qsynth` anyway, launching it if and when I need it rather than `fluidsynth` constantly daemonized in the background. 

---

For more detailed information on any given tunable, check out the official [PipeWire Wiki](https://gitlab.freedesktop.org/pipewire/pipewire/-/wikis/home).
