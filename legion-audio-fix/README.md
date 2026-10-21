# Legion audio fix

This folder holds a temporary fix for the quiet speakers on the Lenovo Legion Pro 7 16IAX10H.

## What this does

- saves your current kernel so you can go back to it later
- installs the AW88399 firmware file used by the speaker amp
- can build a side-by-side patched kernel (for example `7.0.0-22-generic-patched`)
- lets you test another kernel once before making it permanent
- lets you restore the original kernel if the test kernel causes trouble

## Files

- `legion-audio-fix.sh` - the helper script
- `16iax10h-audio-linux-7.0.patch` - vendored audio patch used during kernel build

## How to use it

Run everything with `sudo`.

### 1. Save your current setup and install firmware

```bash
sudo ./legion-audio-fix.sh apply
```

This does not change your kernel. It only saves the current one and installs the firmware file.

### 2. Build and install a patched kernel entry

```bash
sudo ./legion-audio-fix.sh build-patched-kernel
```

By default this builds from your current running kernel config and installs a second entry with `-patched` suffix.
For example, if you are on `7.0.0-22-generic`, the new one should become `7.0.0-22-generic-patched`.

You can also target a specific installed base kernel:

```bash
sudo ./legion-audio-fix.sh build-patched-kernel 7.0.0-22-generic
```

Important:
- this step can take a long time (often 30+ minutes, sometimes much longer)
- keep the laptop on power
- reserve enough free disk space (kernel source + build artifacts can be large)
- the script now writes a full build log to `/usr/src/legion-audio-fix/build-patched-kernel-*.log`
- if RAM is tight, reduce parallelism: `sudo KERNEL_BUILD_JOBS=4 ./legion-audio-fix.sh build-patched-kernel`

### 3. See which kernels are installed

```bash
sudo ./legion-audio-fix.sh list-kernels
```

Look for the new kernel version you want to try.

You should now see both your original kernel and the new `-patched` kernel.

### 4. Test a kernel once

```bash
sudo ./legion-audio-fix.sh test-kernel <kernel-version>
```

Example:

```bash
sudo ./legion-audio-fix.sh test-kernel 7.0.0-22-generic-patched
```

This tells GRUB to use that kernel on the next boot only.
It only works for a kernel you are not already running.

### 5. Keep the patched kernel if it works

```bash
sudo ./legion-audio-fix.sh keep-kernel <kernel-version>
```

Use this after you booted the new kernel and audio looks good.

### 6. Go back to the original kernel

```bash
sudo ./legion-audio-fix.sh rollback
```

This restores the firmware backup and sets the original kernel as the default boot choice again.

## Simple recovery idea

If the test kernel breaks audio or booting, run `rollback`. If the machine will not boot at all, use GRUB's **Advanced options for Ubuntu** menu and pick the saved original kernel.

## Notes

- The build uses the bundled `16iax10h-audio-linux-7.0.patch` first.
- If the bundled patch for your kernel series is missing, the script tries downloading it from the upstream reference repository.
- During config, distro-specific key references are cleared so Ubuntu config can build against vanilla kernel source.
- The original kernel is saved in `/var/lib/legion-audio-fix/state.env`.
- Firmware backups are saved in `/var/backups/legion-audio-fix/`.
