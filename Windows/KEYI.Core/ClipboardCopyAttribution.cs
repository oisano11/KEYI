namespace KEYI.Core;

public static class ClipboardCopyAttribution
{
    // An unknown or different owner is not evidence of the requested copy.
    public static bool IsExpectedCopy(uint expectedProcess, uint ownerProcess,
        uint copiedSequence, uint currentSequence) =>
        expectedProcess != 0 && ownerProcess == expectedProcess
        && copiedSequence == currentSequence;
}
