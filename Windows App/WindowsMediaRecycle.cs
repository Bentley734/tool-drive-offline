using System;
using System.IO;
using System.Runtime.InteropServices;

namespace ToolDriveOffline
{
    // IFileOperation performs the same volume-aware move to the Recycle Bin as Explorer.
    // PreDeleteItem refuses any fallback to permanent deletion.
    internal static class WindowsMediaRecycle
    {
        static readonly Guid ShellItemId = new Guid("43826d1e-e718-42ee-bc55-a1e261c37bfe");
        static readonly Guid FileOperationId = new Guid("3ad05575-8857-4850-9277-11b85bdb8e09");
        [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
        static extern void SHCreateItemFromParsingName(string file, IntPtr bindContext, ref Guid id,
                                                       out IntPtr item);

        public static void Move(string directory, IntPtr owner)
        {
            var id = ShellItemId;
            IntPtr item = IntPtr.Zero;
            IRecordingFileOperation op = null;
            try
            {
                SHCreateItemFromParsingName(directory, IntPtr.Zero, ref id, out item);
                op = (IRecordingFileOperation)Activator.CreateInstance(
                    Type.GetTypeFromCLSID(FileOperationId, true));
                const uint RecycleOnDelete = 0x00080000, EarlyFailure = 0x00100000;
                const uint AllowUndo = 0x0040, NoConfirmation = 0x0010, Silent = 0x0004, NoErrorUI = 0x0400;
                op.SetOperationFlags(RecycleOnDelete | EarlyFailure | AllowUndo | NoConfirmation | Silent |
                                     NoErrorUI);
                if (owner != IntPtr.Zero)
                    op.SetOwnerWindow(owner);
                var sink = new RecordingRecycleSink();
                op.DeleteItem(item, sink);
                op.PerformOperations();
                bool aborted;
                op.GetAnyOperationsAborted(out aborted);
                GC.KeepAlive(sink);
                if (aborted || Directory.Exists(directory))
                    throw new IOException();
            }
            catch (Exception e)
            {
                throw new InvalidDataException("Windows could not move this recording to the Recycle Bin.",
                                               e);
            }
            finally
            {
                if (op != null)
                    Marshal.FinalReleaseComObject(op);
                if (item != IntPtr.Zero)
                    Marshal.Release(item);
            }
        }

        [ComImport, Guid("947aab5f-0a5c-4c13-b4d6-4bf7836fc9f8"),
         InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        interface IRecordingFileOperation
        {
            void Advise(IntPtr sink, out uint cookie);
            void Unadvise(uint cookie);
            void SetOperationFlags(uint flags);
            void SetProgressMessage(IntPtr text);
            void SetProgressDialog(IntPtr dialog);
            void SetProperties(IntPtr properties);
            void SetOwnerWindow(IntPtr window);
            void ApplyPropertiesToItem(IntPtr item);
            void ApplyPropertiesToItems(IntPtr items);
            void RenameItem(IntPtr item, IntPtr name, IntPtr sink);
            void RenameItems(IntPtr items, IntPtr name);
            void MoveItem(IntPtr item, IntPtr folder, IntPtr name, IntPtr sink);
            void MoveItems(IntPtr items, IntPtr folder);
            void CopyItem(IntPtr item, IntPtr folder, IntPtr name, IntPtr sink);
            void CopyItems(IntPtr items, IntPtr folder);
            void DeleteItem(IntPtr item, IRecordingRecycleSink sink);
            void DeleteItems(IntPtr items);
            void NewItem(IntPtr folder, uint attributes, IntPtr name, IntPtr template, IntPtr sink);
            void PerformOperations();
            void GetAnyOperationsAborted([MarshalAs(UnmanagedType.Bool)] out bool aborted);
        }
    }

    [ComVisible(true), Guid("04b0f1a7-9490-44bc-96e1-4296a31252e2"),
     InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IRecordingRecycleSink
    {
        void StartOperations();
        void FinishOperations(int result);
        void PreRenameItem(uint flags, IntPtr item, IntPtr name);
        void PostRenameItem(uint flags, IntPtr item, IntPtr name, int result, IntPtr target);
        void PreMoveItem(uint flags, IntPtr item, IntPtr folder, IntPtr name);
        void PostMoveItem(uint flags, IntPtr item, IntPtr folder, IntPtr name, int result, IntPtr target);
        void PreCopyItem(uint flags, IntPtr item, IntPtr folder, IntPtr name);
        void PostCopyItem(uint flags, IntPtr item, IntPtr folder, IntPtr name, int result, IntPtr target);
        [PreserveSig]
        int PreDeleteItem(uint flags, IntPtr item);
        void PostDeleteItem(uint flags, IntPtr item, int result, IntPtr target);
        void PreNewItem(uint flags, IntPtr folder, IntPtr name);
        void PostNewItem(uint flags, IntPtr folder, IntPtr name, IntPtr template, uint attributes, int result,
                         IntPtr target);
        void UpdateProgress(uint total, uint current);
        void ResetTimer();
        void PauseTimer();
        void ResumeTimer();
    }

    [ComVisible(true), ClassInterface(ClassInterfaceType.None)]
    public sealed class RecordingRecycleSink : IRecordingRecycleSink
    {
        public int PreDeleteItem(uint flags, IntPtr item)
        {
            const uint RecycleRequested = 0x80;
            const int Aborted = unchecked((int)0x80004004);
            return (flags & RecycleRequested) != 0 ? 0 : Aborted;
        }
        public void StartOperations() {}
        public void FinishOperations(int result) {}
        public void PreRenameItem(uint flags, IntPtr item, IntPtr name) {}
        public void PostRenameItem(uint flags, IntPtr item, IntPtr name, int result, IntPtr target) {}
        public void PreMoveItem(uint flags, IntPtr item, IntPtr folder, IntPtr name) {}
        public void PostMoveItem(uint flags, IntPtr item, IntPtr folder, IntPtr name, int result,
                                 IntPtr target)
        {
        }
        public void PreCopyItem(uint flags, IntPtr item, IntPtr folder, IntPtr name) {}
        public void PostCopyItem(uint flags, IntPtr item, IntPtr folder, IntPtr name, int result,
                                 IntPtr target)
        {
        }
        public void PostDeleteItem(uint flags, IntPtr item, int result, IntPtr target) {}
        public void PreNewItem(uint flags, IntPtr folder, IntPtr name) {}
        public void PostNewItem(uint flags, IntPtr folder, IntPtr name, IntPtr template, uint attributes,
                                int result, IntPtr target)
        {
        }
        public void UpdateProgress(uint total, uint current) {}
        public void ResetTimer() {}
        public void PauseTimer() {}
        public void ResumeTimer() {}
    }
}
