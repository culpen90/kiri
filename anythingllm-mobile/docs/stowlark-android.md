# Linux with Stowlark on Android

The **Linux (Stowlark)** chat tool runs reviewed shell and Python scripts in a small Alpine Linux VM on the phone. It works with local models and connected model providers in mobile chats. Each run starts with an empty workspace, without guest networking or phone file mounts. AnythingLLM shows the script and asks you to approve each run.

## Set up the phone

1. On ARM64 Android 8 or newer, [install and open Termux](https://github.com/termux/termux-app#installation). Use the F-Droid or GitHub build with `RUN_COMMAND` result support.
2. Install the emulator inside Termux. The QEMU packages and their dependencies can take about 1 GB on a fresh install.

   ```sh
   pkg install qemu-system-aarch64-headless
   ```

3. Get a trusted `stowlark-android-aarch64.tar.gz` build and its checksum. The [Stowlark Android build instructions](../../docs/android.md#build-from-source) show how to build both from the repository root. Place both files in the same directory accessible from Termux. Run the following from that directory.

   ```sh
   sha256sum -c stowlark-android-aarch64.tar.gz.sha256 &&
     mkdir -p "$HOME/.local" &&
     tar -xzf stowlark-android-aarch64.tar.gz -C "$HOME/.local" &&
     "$HOME/.local/stowlark-android/bin/stowlark-android" doctor
   ```

   Look for `"status":"ready"` in the JSON output.

4. Set `allow-external-apps=true` in `~/.termux/termux.properties` and run `termux-reload-settings`. See [Termux's setup instructions](https://github.com/termux/termux-app/wiki/RUN_COMMAND-Intent#setup-instructions) for the Android permission and external-app setting.
5. In an AnythingLLM Mobile chat, open **Tools** and turn on **Linux (Stowlark)**. Allow **Run commands in Termux environment** when Android prompts. If you previously denied it, grant it in Android's app permissions for AnythingLLM and retry the toggle.
6. Ask the assistant to run `uname -m` and `python3 -c 'print(6 * 7)'` in Stowlark. Review and approve the script. The guest should return `aarch64` and `42`.

## Runtime limits

- Stowlark boots a fresh 256 MiB VM per run and stops it after 90 seconds, including boot. Combine steps that need the same files into one script.
- Keep output small. Termux can truncate large replies, and AnythingLLM shortens returned output to fit the model's context.
- If you stop a chat turn after approval, the already-started VM can continue through its existing deadline.
- Use scripts you trust after review. [Stowlark documents the limits of QEMU software emulation as an isolation boundary.](../../docs/android.md#trust-model)
