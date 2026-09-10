namespace KEYI.Core;

// Nested clipboard probes share one owner so their writes are not mistaken for
// a user's new clipboard content. The platform supplies capture and restoration.
public sealed class ClipboardTransaction(
    Func<uint> currentSequence,
    Func<uint, Task> restoreSnapshot)
{
    private uint? _ownedSequence;

    public void RecordChange(uint sequence) => _ownedSequence = sequence;

    public Task RestoreAsync() =>
        _ownedSequence is uint sequence && currentSequence() == sequence
            ? restoreSnapshot(sequence)
            : Task.CompletedTask;
}
