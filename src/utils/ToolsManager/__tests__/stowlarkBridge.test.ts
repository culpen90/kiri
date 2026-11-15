jest.mock('react-native', () => ({
    NativeModules: {
        Stowlark: {
            getConstants: () => ({ supported: true }),
            run: jest.fn(),
        },
    },
    Platform: { OS: 'android' },
}));
jest.mock('@/i18n', () => ({ __esModule: true, default: {} }));

import { NativeModules } from 'react-native';
import { isValidStowlarkScript, MAX_STOWLARK_SCRIPT_BYTES, runStowlark } from '@/utils/stowlark';

test('accounts for the Termux newline and checks UTF-8 byte length', () => {
    const script = 'é'.repeat((MAX_STOWLARK_SCRIPT_BYTES / 2) - 1);
    expect(isValidStowlarkScript(`${script}a`)).toBe(true);
    expect(isValidStowlarkScript(`${script}a\n`)).toBe(true);
    expect(isValidStowlarkScript(`${script}aa`)).toBe(false);
    expect(isValidStowlarkScript('echo 😀')).toBe(true);
    expect(isValidStowlarkScript('echo \ud800')).toBe(false);
    expect(isValidStowlarkScript('echo \0')).toBe(false);
});

test('preserves a nonzero guest exit and rejects malformed results', async () => {
    const run = NativeModules.Stowlark.run as jest.Mock;
    run.mockResolvedValueOnce('{"status":"exited","exit_code":7,"stdout":"","stderr":"hello\\n"}\n');
    await expect(runStowlark('echo hello >&2; exit 7')).resolves.toEqual({
        status: 'exited', exit_code: 7, stdout: '', stderr: 'hello\n',
    });

    run.mockResolvedValueOnce('{"status":"exited","stdout":"","stderr":""}');
    await expect(runStowlark('true')).rejects.toThrow('invalid run result');
});
