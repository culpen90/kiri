jest.mock('react-native', () => ({ AppState: { currentState: 'active' } }));
jest.mock('@/i18n', () => ({ __esModule: true, default: { t: (key: string) => key } }));
jest.mock('@/utils/constants', () => ({ generateUUID: () => 'approval-id' }));
jest.mock('@/utils/chat/contextCompaction', () => ({ truncateMiddle: (text: string, maxChars: number) => text.slice(0, maxChars) }));
jest.mock('@/utils/stowlark', () => ({
    MAX_STOWLARK_SCRIPT_BYTES: 64 * 1024,
    isStowlarkSupported: jest.fn(() => true),
    isValidStowlarkScript: jest.fn((script: unknown) => typeof script === 'string' && !!script.trim()),
    prepareStowlark: jest.fn(),
    runStowlark: jest.fn(),
}));
jest.mock('../toolAutoApprovals', () => ({
    addAutoApproval: jest.fn(),
    isAutoApproved: jest.fn(async () => true),
}));
jest.mock('@/store/UIStore', () => ({ __esModule: true, default: {} }));

import { AppState } from 'react-native';
import { isStowlarkSupported, runStowlark } from '@/utils/stowlark';
import ToolApproval from '../toolApproval';
import { addAutoApproval, isAutoApproved } from '../toolAutoApprovals';
import stowlark from '../tools/stowlark';

const script = 'uname -s\npython3 -c "print(6 * 7)"\n';
const call = JSON.stringify({ script: script.slice(0, -1) });
const run = jest.mocked(runStowlark);

beforeEach(() => {
    jest.clearAllMocks();
    AppState.currentState = 'active';
    jest.mocked(isStowlarkSupported).mockReturnValue(true);
    run.mockResolvedValue({ status: 'exited', exit_code: 0, stdout: 'Linux\n42\n', stderr: '' });
});

test('requires approval for the exact script and discards any always-approve preference', async () => {
    const emit = jest.fn();
    const execution = stowlark.execute(call, emit);
    expect(emit).toHaveBeenCalledWith('request_tool_approval', expect.objectContaining({
        skillName: 'run_linux_script',
        payload: { script },
        allowAlwaysApprove: false,
    }));
    expect(isAutoApproved).not.toHaveBeenCalled();
    expect(run).not.toHaveBeenCalled();

    ToolApproval.respond('approval-id', true, { always: true });
    expect(JSON.parse(await execution)).toEqual({ status: 'exited', exit_code: 0, stdout: 'Linux\n42\n', stderr: '' });
    expect(run).toHaveBeenCalledWith(script);
    expect(addAutoApproval).not.toHaveBeenCalled();
});

test('never executes a rejected or aborted script', async () => {
    const emit = jest.fn();
    const rejected = stowlark.execute(call, emit);
    ToolApproval.respond('approval-id', false);
    await expect(rejected).resolves.toMatch(/rejected/);

    const controller = new AbortController();
    const cancelled = stowlark.execute(call, emit, { signal: controller.signal });
    controller.abort();
    await expect(cancelled).resolves.toMatch(/aborted/);
    expect(ToolApproval.isPending('approval-id')).toBe(false);
    expect(run).not.toHaveBeenCalled();
});

test('rejects malformed, background, unattended and unsupported requests before asking', async () => {
    const emit = jest.fn();
    await expect(stowlark.execute('{bad JSON', emit)).resolves.toMatch(/non-empty/);
    await expect(stowlark.execute({ script: 42 }, emit)).resolves.toMatch(/non-empty/);
    await expect(stowlark.execute(call, emit, { autoApproveTools: true })).resolves.toMatch(/foreground/);
    AppState.currentState = 'background';
    await expect(stowlark.execute(call, emit)).resolves.toMatch(/foreground/);
    AppState.currentState = 'active';
    jest.mocked(isStowlarkSupported).mockReturnValue(false);
    await expect(stowlark.execute(call, emit)).resolves.toMatch(/ARM64 Android/);

    expect(emit).not.toHaveBeenCalled();
    expect(run).not.toHaveBeenCalled();
    expect(stowlark.defaultEnabled).toBe(false);
    expect(stowlark.hiddenFromScheduledJobs).toBe(true);
});

test('rechecks foreground state and cancellation after approval', async () => {
    const emit = jest.fn();
    const firstRun = stowlark.execute(call, emit);
    ToolApproval.respond('approval-id', true);
    AppState.currentState = 'background';
    await expect(firstRun).resolves.toMatch(/foreground/);

    AppState.currentState = 'active';
    const controller = new AbortController();
    const secondRun = stowlark.execute(call, emit, { signal: controller.signal });
    ToolApproval.respond('approval-id', true);
    controller.abort();
    await expect(secondRun).rejects.toMatchObject({ name: 'ChatAbortedError' });
    expect(run).not.toHaveBeenCalled();
});

test('preserves VM status and bounds large outputs returned to chat', async () => {
    run.mockResolvedValue({ status: 'timeout', stdout: 'a'.repeat(4_000), stderr: 'b'.repeat(4_000) });
    const execution = stowlark.execute({ script }, jest.fn());
    ToolApproval.respond('approval-id', true);

    expect(JSON.parse(await execution)).toEqual({ status: 'timeout', stdout: 'a'.repeat(2_000), stderr: 'b'.repeat(2_000) });
});

test('returns a launcher failure as a tool result', async () => {
    run.mockRejectedValue(new Error('QEMU is unavailable.'));
    const execution = stowlark.execute(call, jest.fn());
    ToolApproval.respond('approval-id', true);

    await expect(execution).resolves.toMatch(/Stowlark could not complete the run.*QEMU is unavailable/);
});
