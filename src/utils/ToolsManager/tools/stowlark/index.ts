import { AppState } from 'react-native';
import i18n from '@/i18n';
import { throwIfAborted } from '@/utils/chat/abort';
import { truncateMiddle } from '@/utils/chat/contextCompaction';
import {
    isStowlarkSupported,
    isValidStowlarkScript,
    MAX_STOWLARK_SCRIPT_BYTES,
    prepareStowlark,
    runStowlark,
} from '@/utils/stowlark';
import { type ToolManagerTool } from '@/utils/ToolsManager';
import ToolApproval from '@/utils/ToolsManager/toolApproval';
import { parseToolArgs } from '../createFiles/shared';

const TOOL_NAME = 'run_linux_script';
const MAX_OUTPUT_CHARS_PER_STREAM = 2_000;
const FOREGROUND_REQUIRED = 'Stowlark needs a foreground chat so the user can review the script. No script ran.';

const stowlark: ToolManagerTool = {
    id: 'stowlark',
    get name() { return i18n.t('tools.stowlark.name'); },
    get description() { return i18n.t('tools.stowlark.description'); },
    defaultEnabled: false,
    category: 'default',
    hiddenFromScheduledJobs: true,
    omitArgumentsFromSignature: true,
    requestPermission: prepareStowlark,
    definition: {
        type: 'function',
        function: {
            name: TOOL_NAME,
            description: 'Run a short POSIX shell script with BusyBox and Python 3 on the phone, using Stowlark’s temporary Alpine Linux VM. Use it for calculation, text processing, or testing local code. Each run starts with an empty workspace and has no network or access to phone files. The user reviews each script before it runs. Returns the execution status, exit code when available, stdout, and stderr.',
            parameters: {
                type: 'object',
                properties: {
                    script: { type: 'string', description: `Complete UTF-8 shell script. Pass Python through the shell using python3. Maximum ${MAX_STOWLARK_SCRIPT_BYTES} bytes.` },
                },
                required: ['script'],
            },
        },
    },
    config: {},
    async execute(args, streamEmitter, { signal, autoApproveTools } = {}) {
        throwIfAborted(signal);
        if (!isStowlarkSupported()) return 'Stowlark is available on ARM64 Android devices. No script ran.';
        if (autoApproveTools || AppState.currentState !== 'active') return FOREGROUND_REQUIRED;

        const argsScript = parseToolArgs<{ script?: unknown }>(args, {}).script;
        if (!isValidStowlarkScript(argsScript)) return `Provide a non-empty UTF-8 shell script of at most ${MAX_STOWLARK_SCRIPT_BYTES} bytes without NUL characters. No script ran.`;
        // Termux adds a final newline to stdin. Include it in the script the user reviews.
        const script = argsScript.endsWith('\n') ? argsScript : `${argsScript}\n`;

        const approval = await ToolApproval.request({
            skillName: TOOL_NAME,
            description: i18n.t('tools.stowlark.approval_description'),
            payload: { script },
            streamEmitter,
            signal,
            allowAlwaysApprove: false,
        });
        if (!approval.approved) return `${approval.message} No script ran.`;
        throwIfAborted(signal);
        if (AppState.currentState !== 'active') return FOREGROUND_REQUIRED;

        streamEmitter('report_status', i18n.t('tools.stowlark.status_running'));
        try {
            const result = await runStowlark(script);
            throwIfAborted(signal);
            return JSON.stringify({
                ...result,
                stdout: truncateMiddle(result.stdout, MAX_OUTPUT_CHARS_PER_STREAM),
                stderr: truncateMiddle(result.stderr, MAX_OUTPUT_CHARS_PER_STREAM),
            });
        } catch (error) {
            throwIfAborted(signal);
            return `Stowlark could not complete the run. ${error instanceof Error ? error.message : 'Unknown error.'}`;
        }
    },
};

export default stowlark;
