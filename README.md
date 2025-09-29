# Junk Drawer
A collection of miscellaneous resources for Linux gaming and system tasks. These are low-effort and largely unpolished, but I found them useful, so you might also.

## Scripts
| Category | Script | Description |
|----------|--------|-------------|
| Emulation | [network_tune_batocera](network_tune_batocera) | Sets custom network interface parameters (e.g., MTU, speed) at Batocera startup |
| Emulation | [nfs_mount_batocera](nfs_mount_batocera) | Mounts NFS exports locally as a client on Batocera Linux, e.g. for Kodi |
| Emulation | [psp-shrink-ray.sh](psp-shrink-ray.sh) | Compresses PS2/PSP images to CHD format, deleting originals on success |
| Hardware | [set-rdna-oc-fan.sh](set-rdna-oc-fan.sh) | Creates and applies overclocking / fan profiles for AMD RDNA GPUs |
| Multimedia | [midi2wav.sh](midi2wav.sh) | Convert MIDI file(s) to digital audio like WAV, FLAC, AAC or MP3 |
| Multimedia | [pipewire_tuning_guide.md](pipewire_tuning_guide.md) | Quick & dirty guide to setting up low-latency, multi-rate PipeWire |
| Multimedia | [sonicsqueezer.sh](sonicsqueezer.sh) | A multi-threaded audio converter for WAV and FLAC to MP3, AAC, OGG, and more | 

## Installation
Clone the whole repo:
```bash
git clone https://github.com/cwadge/junk-drawer.git
```

or download an individual script, e.g.
```bash
wget https://raw.githubusercontent.com/cwadge/junk-drawer/main/set-rdna-oc-fan.sh
```

## Usage
Navigate to the script's folder and run it with appropriate arguments. See each script's `--help` or inline comments for details.

## Contributing
The usual: you're welcome to fork, submit issues, PRs, etc.

## License
MIT License ([LICENSE](https://opensource.org/license/MIT)) - feel free to use, modify, and share.

---

_A bunch of B-grade scripts by Chris Wadge_
