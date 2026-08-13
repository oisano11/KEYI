namespace HanYi.Windows;

internal static class Program
{
    private const string SingleInstanceMutexName = @"Local\HanYi.InputTranslator";

    [STAThread]
    private static void Main()
    {
        using var singleInstance = new Mutex(
            initiallyOwned: true,
            SingleInstanceMutexName,
            out var isFirstInstance);
        if (!isFirstInstance)
        {
            return;
        }

        try
        {
            ApplicationConfiguration.Initialize();
            using var controller = new AppController();
            controller.Initialize();
            Application.Run();
        }
        finally
        {
            singleInstance.ReleaseMutex();
        }
    }
}
