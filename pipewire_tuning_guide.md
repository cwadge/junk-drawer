# Tuning PipeWire

This is a quick and dirty guide to low-latency, high-fidelity audio via PipeWire in Linux. It's really just notes based on my recent research into how to get the most out of PipeWire (v1.4.7) for my use case, but it's working fantastically for me and it may help you get pointed in the right direction.

## Basic Linux Tuning

It's really desirable to be running a kernel with low latency support, e.g. XanMod, Liquorix, zen, or an 'RT' patched kernel from your distro. To take full advantage, we're also going to need to give our audio user(s) permissions to run in real-time.

Create something like `/etc/security/limits.d/90-audio.conf` if it doesn't exist, and add:

```
#
# Realtime audio tuning, per JACK's recommendations
#

@audio   -  rtprio     95
@audio   -  memlock    unlimited
@audio   -  nice      -19
```
PipeWire runs at `-11` by default, at least at present. If you ever want to use the PipeWire JACK plugin `pipewire-jack`, for JACK applications to output via PipeWire, allowing it to run at up to `-19` might be best. If not, `-11` is probably fine here.

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

In my case, I'm using my discrete sound card for playback, which is enumerated as `card 0`, `device 0`. This would typically be exposed to the system as `/proc/asound/card0/stream0`, and this will be the case on the vast majority of sound cards in Linux. Grabbing the sample rates your card supports in hardware is really easy using this interface. For example, here's the output from a sound card in someone else's system:

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

I have a weird card, however, and it doesn't use this straightforward `/proc` convention. So I had to use a different method (which should also work with any supported card out there):

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

In this case, I'm just playing a null WAV file I made with `sox`, but it could be literally any sound file that's supported by `aplay`. We only care about the hardware dump output, which tells us: `RATE: [32000 192000]`; this is a range, not a series like the previous card we looked at. That means this particular card supports a floor and a ceiling in hardware, and everything in between, so we can use any rates in that range natively. Nice.

## Setting Up WirePlumber

WirePlumber is the modular session / policy manager for PipeWire.

Running the latest version of `wireplumber` that's readily available to us is a good idea, so we can get all the latest bug fixes and optimizations. In my case, I'm running `Debian 13` aka "Trixie", so I'd do:

```bash
sudo apt -t trixie-backports install wireplumber
```

### Configuring WirePlumber
Now that we know what range or series of sample rates our card supports natively, we can apply it to WirePlumber. Depending on whether we're running version `<= 0.4` or `>=0.5`, we'll either need to create a `Lua` or a `SPA-JSON` config.

#### For Old WirePlumber (0.4 or earlier)

Create `~/.config/wireplumber/main.lua.d/` if it doesn't already exist:

```bash
mkdir -p ~/.config/wireplumber/main.lua.d/
```

Then add `~/.config/wireplumber/main.lua.d/50-alsa-rate.lua` with a stanza like the following:

```lua
alsa_monitor.rules = {
  {
    matches = {
      {
        { "node.name", "matches", "alsa_output.*" },
      },
    },
    apply_properties = {
      ["audio.rate"] = 48000,
      ["audio.allowed-rates"] = { 44100, 48000, 88200, 96000, 176400, 192000 },
      ["api.alsa.period-size"] = 128,
      ["api.alsa.headroom"] = 0,
      ["resample.quality"] = 10,
    },
  },
}
```
#### For Newer WirePlumber (0.5 or later)

Create `~/.config/wireplumber/wireplumber.conf.d/` if it doesn't exist:

```bash
mkdir -p ~/.config/wireplumber/wireplumber.conf.d/
```

Add a new config as `~/.config/wireplumber/wireplumber.conf.d/50-alsa-rate.conf`:

```
monitor.alsa.rules = [
  {
    matches = [
      {
        node.name = "~alsa_output.*"
      }
    ]
    actions = {
      update-props = {
        audio.rate = 48000
        audio.allowed-rates = [ 44100, 48000, 88200, 96000, 176400, 192000 ]
        api.alsa.period-size = 128
        api.alsa.headroom = 0
        resample.quality = 10
      }
    }
  }
]
```

The `audio.rate` value is going to be our default sample rate. For my needs (mostly games, music, YT and similar), 48kHz is my sweet spot. It's *probably* yours, too.

`audio.allowed-rates` are what we want to advertise to the system as supported. I chose these because they're standard sample rates and my card supports them without resampling. On the other card I looked at earlier, it only supported a series of sample rates that didn't include the less standard `88200` or `176400`, so I'd not have set those rates for that particular card. As my card allows a range from `32000 - 192000`, I'm all good for any arbitrary sample rates, and PipeWire itself presently supports up to 32 allowed rates.

Note that while I *could* include 32k, this is generally not recommended, as the sample rate isn't commonly encountered outside of VoIP, and it's better to just let the system resample in software for sample rates that low.

`resample.quality` is a range of `0 - 14` with `0` essentially being "linear" and `14` being the maximum quality. A value of `10` is generally considered the sweet spot for modern hardware, `4` being a good middle ground for constrained or embedded systems, and `14` being uncompromising but computationally expensive. Ideally we're playing sample rates that are supported directly by our hardware and our configuration, and no resampling will even be necessary, though there's always the odd edge case or two.

Note also that this setup targets *all* nodes with `node.name = "~alsa_output.*"` for the sake of simplicity. If this isn't what you want, you could certainly have multiple stanzas, each with different policies, targeted at specific audio devices instead. I'll leave that scenario as an exercise for the reader.

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
Our quantums are our variable buffer size. Too small and we may have underruns if the card's too low-end, our system is too busy or too weak, etc. Too big and we'll cause unnecessary audio latency. 

To calculate latency, we can use the following formula:

$$
\text{Latency (ms)} = \left( \frac{\text{quantum (samples)}}{\text{sample rate (Hz)}} \right) \times 1000
$$

So for 48kHz audio playback with a quantum of 256:

$$
\begin{aligned}
\text{Latency (ms)} &= \left( \frac{256}{48000} \right) \times 1000 \\
                    &= \frac{256}{48} \\
                    &\approx 5.33 \\
\end{aligned}
$$

About **5.3ms**. 

**Note:** The quantum scales based on sample rate. For example, with a `default.clock.rate` of `48000` and a `default.clock.quantum` of `256`, the quantum will scale to `1024` if the sample rate is `192000`&mdash;4x the sample rate = 4x the quantum. The latency remains consistent.

A `default.clock.quantum` of 256 works well for my particular system:

 - Ryzen 7 3700X @4.63GHz (-48mV)
 - 32GB DDR4 3200 (XMP)
 - ASUS Xonar DX (C-Media Electronics Inc CMI8788 [Oxygen HD Audio])
 - Latest [XanMod](https://xanmod.org/) kernel

Despite the somewhat modest and outdated hardware, I haven't had any cut-outs, clicks, pops, distortion, underruns, or any other sound issues even when playing multiple audio streams at once under load. This includes heavy games like *Mount & Blade II: Bannerlord*, with hundreds of sounds playing simultaneously, and hundreds of units on the field. But, YMMV. Consider this a starting point. If you find that you can get away with smaller buffers or need larger ones, do what you need to do. If you do need to tune, I'd by experimenting with the `default.clock.quantum` value.

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

In my case, I tested some 192kHz FLAC from [www.2L.no](https://www.2L.no/) via `mplayer`, for maximum verbosity:

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

As you can see, the `AO` (audio out) rate that's being output is 192kHz. Sounds amazing, and I can still stream basic 44.1kHz YT stuff or whatever, simultaneously. Excellent.

We can use the `pw-dump` tool to examine our latency, among many other things:

```bash
pw-dump | grep -i latency
```

To profile in near real-time, the `pw-top` tool is extremely useful:

```
S   ID  QUANT   RATE    WAIT    BUSY   W/Q   B/Q  ERR FORMAT           NAME 
S   30      0      0    ---     ---   ---   ---     0                  Dummy-Driver
S   31      0      0    ---     ---   ---   ---     0                  Freewheel-Driver
S   50      0      0    ---     ---   ---   ---     0                  Midi-Bridge
S   53      0      0    ---     ---   ---   ---     0                  bluez_midi.server
R   56   4096 192000  68.8us  87.7us  0.00  0.00    0    S32LE 2 48000 alsa_output.pci-0000_08_04.0.analog-stereo
R   64   6000 192000  12.2us  22.9us  0.00  0.00    0   S32LE 2 192000  + alsa_playback.mplayer
R   81   1024  48000  10.9us  51.7us  0.00  0.00    0    F32LE 2 48000  + Brave
R   85    256  48000  39.6us   0.8us  0.01  0.00    0   BGRx 2560x1396 kwin_wayland
R   76      0      0   0.0us   0.0us  0.00  0.00    0   BGRx 2560x1396  + plasmashell
```
It also supports batch output, so you can log stats in the background, for example:

```bash
pw-top -b > /tmp/pipewire-latency-`date +%F`.log
```

As for any buffer underruns or other hiccups, we can monitor WirePlumber via `journalctl`:

```bash
journalctl --user -u wireplumber -f | grep -E "underrun|xrun|resume"
```

And for deep inspection of your WirePlumber instance for fine-tuning or troubleshooting, there's `wpctl`:

```
$ wpctl status
PipeWire 'pipewire-0' [1.4.7, chris@crow, cookie:2686875995]
 └─ Clients:
        33. pipewire                            [1.4.7, chris@crow, pid:1924]
        34. WirePlumber                         [1.4.7, chris@crow, pid:1923]
        43. kwin_wayland                        [1.4.7, chris@crow, pid:1975]
        47. WirePlumber [export]                [1.4.7, chris@crow, pid:1923]
        57. libcanberra                         [1.4.7, chris@crow, pid:2122]
        58. xdg-desktop-portal                  [1.4.7, chris@crow, pid:1981]
        59.                                     [1.4.7, chris@crow, pid:2122]
        60. libcanberra                         [1.4.7, chris@crow, pid:2172]
        61. plasmashell                         [1.4.7, chris@crow, pid:2172]
        62.                                     [1.4.7, chris@crow, pid:2172]
        63. Steam Voice Settings                [1.4.7, chris@crow, pid:2938]
        65. Brave input                         [1.4.7, chris@crow, pid:6495]
        67. Steam                               [1.4.7, chris@crow, pid:2938]
        76. wpctl                               [1.4.7, chris@crow, pid:8363]

Audio
 ├─ Devices:
 │      48. CMI8788 [Oxygen HD Audio] (Virtuoso 100 (Xonar DX)) [alsa]
 │      49. Navi 48 HDMI/DP Audio Controller    [alsa]
 │  
 ├─ Sinks:
 │  *   56. CMI8788 [Oxygen HD Audio] (Virtuoso 100 (Xonar DX)) Analog Stereo [vol: 1.00]
 │  
 ├─ Sources:
 │  
 ├─ Filters:
 │  
 └─ Streams:

Video
 ├─ Devices:
 │  
 ├─ Sinks:
 │  
 ├─ Sources:
 │  
 ├─ Filters:
 │  
 └─ Streams:

Settings
 └─ Default Configured Devices:
         0. Audio/Sink    alsa_output.pci-0000_08_04.0.analog-stereo
         
$ wpctl inspect 56
id 56, type PipeWire:Interface:Node
    alsa.card = "0"
    alsa.card_name = "Xonar DX"
    alsa.class = "generic"
    alsa.components = "CS4398 CS4362A CS5361 AV200"
    alsa.device = "0"
    alsa.driver_name = "snd_virtuoso"
    alsa.id = "Multichannel"
    alsa.long_card_name = "Asus Virtuoso 100 at 0xf000, irq 33"
    alsa.mixer_name = "AV200"
    alsa.name = "Multichannel"
    alsa.resolution_bits = "16"
    alsa.subclass = "generic-mix"
    alsa.subdevice = "0"
    alsa.subdevice_name = "subdevice #0"
    alsa.sync.id = "00000000:00000000:00000000:00000000"
    api.alsa.card.longname = "Asus Virtuoso 100 at 0xf000, irq 33"
    api.alsa.card.name = "Xonar DX"
    api.alsa.path = "front:0"
    api.alsa.pcm.card = "0"
    api.alsa.pcm.stream = "playback"
    api.alsa.period-size = "128"
    audio.allowed-rates = "[ 44100, 48000, 88200, 96000, 176400, 192000 ]"
    audio.channels = "2"
    audio.position = "FL,FR"
    audio.rate = "48000"
    card.profile.device = "6"
  * client.id = "47"
    clock.quantum-limit = "8192"
    device.api = "alsa"
    device.class = "sound"
    device.icon-name = "audio-card-analog"
  * device.id = "48"
    device.profile.description = "Analog Stereo"
    device.profile.name = "analog-stereo"
    device.routes = "1"
  * factory.id = "19"
    factory.name = "api.alsa.pcm.sink"
    library.name = "audioconvert/libspa-audioconvert"
  * media.class = "Audio/Sink"
  * node.description = "CMI8788 [Oxygen HD Audio] (Virtuoso 100 (Xonar DX)) Analog Stereo"
    node.driver = "true"
    node.loop.name = "data-loop.0"
  * node.name = "alsa_output.pci-0000_08_04.0.analog-stereo"
  * node.nick = "Multichannel"
    node.pause-on-idle = "false"
  * object.path = "alsa:acp:DX:6:playback"
  * object.serial = "56"
    port.group = "playback"
  * priority.driver = "1009"
  * priority.session = "1009"
    resample.quality = "10"
```

I've only really touched lightly on the utilities you've got at your disposal. Feel free to experiment. 

## Extras

Optionally, if you're not routinely playing MIDI from your desktop as a matter of course, you can disable `fluidsynth` sessions, which can free up resources and avoid potential conflicts.

```bash
systemctl --user stop fluidsynth
systemctl --user mask fluidsynth
```
Personally I prefer `qsynth` anyway, launching it if and when I need it rather than `fluidsynth` constantly daemonized in the background. 

---

For more detailed information on any given tunable, check out the official [PipeWire Wiki](https://gitlab.freedesktop.org/pipewire/pipewire/-/wikis/home).
