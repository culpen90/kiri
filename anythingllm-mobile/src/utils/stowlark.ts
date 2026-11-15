import { Buffer } from 'buffer';
import { Alert, Linking, NativeModules, PermissionsAndroid, Platform } from 'react-native';
import i18n from '@/i18n';

const TERMUX_PERMISSION = 'com.termux.permission.RUN_COMMAND' as Parameters<typeof PermissionsAndroid.request>[0];
const SETUP_URL = 'https://github.com/stowlark/stowlark/blob/main/anythingllm-mobile/docs/stowlark-android.md';

export const MAX_STOWLARK_SCRIPT_BYTES = 64 * 1024;

type StowlarkNativeModule = {
    getConstants(): { supported: boolean };
    check(): Promise<string>;
    run(script: string): Promise<string>;
};

type StowlarkOutput = { stdout: string; stderr: string };
export type StowlarkResult = StowlarkOutput & (
    { status: 'exited'; exit_code: number } |
    { status: 'timeout' | 'output_limit'; exit_code?: never }
);

function getBridge(): StowlarkNativeModule | undefined {
    if (Platform.OS !== 'android') return undefined;
    const bridge = NativeModules.Stowlark as StowlarkNativeModule | undefined;
    return bridge?.getConstants().supported ? bridge : undefined;
}

export function isStowlarkSupported(): boolean {
    return getBridge() !== undefined;
}

export function isValidStowlarkScript(script: unknown): script is string {
    return typeof script === 'string' && script.trim().length > 0 &&
        !script.includes('\0') && !/[\ud800-\udfff]/u.test(script) &&
        Buffer.byteLength(script, 'utf8') + (script.endsWith('\n') ? 0 : 1) <= MAX_STOWLARK_SCRIPT_BYTES;
}

function parseResponse(raw: string): Record<string, unknown> {
    let result: unknown;
    try {
        result = JSON.parse(raw);
    } catch {
        throw new Error('Stowlark returned invalid JSON.');
    }
    if (result === null || typeof result !== 'object' || Array.isArray(result)) {
        throw new Error('Stowlark returned an invalid response.');
    }
    return result as Record<string, unknown>;
}

export async function runStowlark(script: string): Promise<StowlarkResult> {
    const bridge = getBridge();
    if (!bridge) throw new Error('Stowlark requires ARM64 Android.');
    if (!isValidStowlarkScript(script)) throw new Error('Expected a nonempty UTF-8 script of at most 64 KiB including the final newline, with no NUL bytes.');

    const { status, stdout, stderr, exit_code, message } = parseResponse(await bridge.run(script));
    if (status === 'error') {
        throw new Error(typeof message === 'string' ? message.slice(0, 500) : 'Stowlark could not start Linux.');
    }
    if (typeof stdout === 'string' && typeof stderr === 'string') {
        if (status === 'timeout' || status === 'output_limit') return { status, stdout, stderr };
        if (status === 'exited' && typeof exit_code === 'number' && Number.isInteger(exit_code) && exit_code >= 0 && exit_code <= 255) {
            return { status, stdout, stderr, exit_code };
        }
    }
    throw new Error('Stowlark returned an invalid run result.');
}

/** Verify prerequisites when the user enables the tool in the chat Tools sheet. */
export async function prepareStowlark(): Promise<boolean> {
    const bridge = getBridge();
    if (!bridge) return false;

    let permissionDenied = false;
    try {
        // If Termux is absent Android denies this immediately. The setup dialog covers that case.
        const permission = await PermissionsAndroid.request(TERMUX_PERMISSION);
        permissionDenied = permission !== PermissionsAndroid.RESULTS.GRANTED;
        if (!permissionDenied) {
            const result = parseResponse(await bridge.check());
            if (result.status === 'ready' && result.api_version === 1 && result.network === false && result.host_mounts === false) {
                return true;
            }
        }
    } catch {
        // The user can complete Termux setup and try the toggle again.
    }

    Alert.alert(i18n.t('tools.stowlark.setup_title'), i18n.t('tools.stowlark.setup_message'), [
        { text: i18n.t('common.ok'), style: 'cancel' },
        { text: i18n.t('common.learn_more'), onPress: () => { Linking.openURL(SETUP_URL).catch(() => {}); } },
        ...(permissionDenied ? [{ text: i18n.t('tools.stowlark.open_app_settings'), onPress: () => { Linking.openSettings().catch(() => {}); } }] : []),
    ]);
    return false;
}
