VERSION 1.0 CLASS
BEGIN
  MultiUse = -1  'True
  Persistable = 0  'NotPersistable
  DataBindingBehavior = 0  'vbNone
  DataSourceBehavior  = 0  'vbNone
  MTSTransactionMode  = 0  'NotAnMTSObject
END
Attribute VB_Name = "pdUnicode"
Attribute VB_GlobalNameSpace = False
Attribute VB_Creatable = True
Attribute VB_PredeclaredId = False
Attribute VB_Exposed = False
'***************************************************************************
'PhotoDemon Unicode Helper Class
'Copyright 2015-2017 by Tanner Helland
'Created: 04/February/15
'Last updated: 09/February/17
'Last update: let the system parse command-line parameters for us, and return the result inside a pdStringStack
'Dependencies: pdSystemInfo (for determining OS version, among other things)
'              Uniscribe module (Uniscribe is unavoidable for some advanced text processing)
'
'This class provides a variety of helper functions for dealing with Unicode text.  A number of other PD classes (e.g. pdFSO) rely on it.
'
'Thank you to the many invaluable references I used while constructing this class, particularly:
' - Dana Seaman's UnicodeTutorialVB (http://www.cyberactivex.com/UnicodeTutorialVb.htm)
'
'All source code in this file is licensed under a modified BSD license.  This means you may use the code in your own
' projects IF you provide attribution.  For more information, please visit http://photodemon.org/about/license/
'
'***************************************************************************

Option Explicit

'Helper APIs for dealing with various charset conversions.
Private Const CP_UTF8 As Long = 65001
Private Declare Function MultiByteToWideChar Lib "kernel32" (ByVal CodePage As Long, ByVal dwFlags As Long, ByVal lpMultiByteStr As Long, ByVal cbMultiByte As Long, ByVal lpWideCharStr As Long, ByVal cchWideChar As Long) As Long
Private Declare Function WideCharToMultiByte Lib "kernel32" (ByVal CodePage As Long, ByVal dwFlags As Long, ByVal lpWideCharStr As Long, ByVal cchWideChar As Long, ByVal lpMultiByteStr As Long, ByVal cchMultiByte As Long, ByVal lpDefaultChar As Long, ByVal lpUsedDefaultChar As Long) As Long

'Base 64 en/decoding can be handled by the API
Private Const CRYPT_STRING_BASE64 As Long = 1&
Private Const CRYPT_STRING_NOCR As Long = &H80000000
Private Const CRYPT_STRING_NOCRLF As Long = &H40000000

Private Declare Function CryptBinaryToString Lib "Crypt32" Alias "CryptBinaryToStringW" (ByRef pbBinary As Byte, ByVal cbBinary As Long, ByVal dwFlags As Long, ByVal pszString As Long, ByRef pcchString As Long) As Long
Private Declare Function CryptStringToBinary Lib "Crypt32" Alias "CryptStringToBinaryW" (ByVal pszString As Long, ByVal cchString As Long, ByVal dwFlags As Long, ByVal pbBinary As Long, ByRef pcbBinary As Long, ByRef pdwSkip As Long, ByRef pdwFlags As Long) As Long

'This class provides a lot of interop for API-style strings
Private Const MAX_PATH As Long = 260
Private Declare Function GetCommandLineW Lib "kernel32" () As Long
Private Declare Function LocalFree Lib "kernel32" (ByVal hMem As Long) As Long
Private Declare Function lstrcpynW Lib "kernel32" (ByVal lpString1 As Long, ByVal lpString2 As Long, ByVal iMaxLength As Long) As Long
Private Declare Function lstrcpyA Lib "kernel32" (ByVal lpBuffer As String, ByVal lpString As Long) As Long
Private Declare Function lstrlenW Lib "kernel32" (ByVal lpString As Long) As Long
Private Declare Function lstrlenA Lib "kernel32" (ByVal lpString As Long) As Long
Private Declare Sub CopyMemoryStrict Lib "kernel32" Alias "RtlMoveMemory" (ByVal lpDst As Long, ByVal lpSrc As Long, ByVal byteLength As Long)
Private Declare Function SysAllocString Lib "oleaut32" (ByVal Ptr As Long) As Long
Private Declare Function SysAllocStringByteLen Lib "oleaut32" (ByVal Ptr As Long, ByVal Length As Long) As String
Private Declare Function CommandLineToArgvW Lib "shell32" (ByVal lpCmdLine As Long, pNumArgs As Long) As Long
Private Declare Function PathCompactPathEx Lib "shlwapi" Alias "PathCompactPathExW" (ByVal pszOutPointer As Long, ByVal pszSrcPointer As Long, ByVal cchMax As Long, ByVal dwFlags As Long) As Long
Private Declare Function PutMem4 Lib "msvbvm60.dll" (ByVal srcAddr As Long, ByVal newVal As Long) As Long

'LCMapString functions provide support for changing Unicode string case (including CJK support like simplified <-> traditional Chinese characters).
' Note that two variants are provided - one for XP, and another for Vista+.  MSDN explicitly states that Vista+ applications should use the newer function.
' (PD will switch between the two automatically.)
Private Declare Function LCMapStringW Lib "kernel32" (ByVal localeID As Long, ByVal dwMapFlags As REMAP_STRING_API, ByVal lpSrcStringPtr As Long, ByVal lenSrcString As Long, ByVal lpDstStringPtr As Long, ByVal lenDstString As Long) As Long

'Vista+ only!  (Note the lack of a trailing W in the function name.)
Private Declare Function LCMapStringEx Lib "kernel32" (ByVal lpLocaleNameStringPt As Long, ByVal dwMapFlags As REMAP_STRING_API, ByVal lpSrcStringPtr As Long, ByVal lenSrcString As Long, ByVal lpDstStringPtr As Long, ByVal lenDstString As Long, ByVal lpVersionInformationPtr As Long, ByVal lpReserved As Long, ByVal sortHandle As Long) As Long

'Both LCMapString variants use the same constants
Private Enum REMAP_STRING_API
    LCMAP_LOWERCASE = &H100&
    LCMAP_UPPERCASE = &H200&
    LCMAP_TITLECASE = &H300&      'Windows 7 only!

    LCMAP_HIRAGANA = &H100000
    LCMAP_KATAKANA = &H200000

    LCMAP_LINGUISTIC_CASING = &H1000000     'Per MSDN, "Use linguistic rules for casing, instead of file system rules (default)."
                                            '           This flag is valid with LCMAP_LOWERCASE or LCMAP_UPPERCASE only."

    LCMAP_SIMPLIFIED_CHINESE = &H2000000
    LCMAP_TRADITIONAL_CHINESE = &H4000000
End Enum

Private Const LOCALE_SYSTEM_DEFAULT As Long = &H800&

'Sometimes we need to retrieve system info, as a lot of Unicode APIs vary by OS version
Private cSysInfo As pdSystemInfo

'Given an arbitrary pointer (often to a VB array, but it doesn't matter) and a length IN BYTES, copy that chunk
' of bytes to a VB string.  The bytes must already be in Unicode format (UCS-2 or UTF-16).
Friend Function ConvertUTF16PointerToVBString(ByVal srcPointer As Long, ByVal lengthInBytes As Long, Optional ByVal trimNullChars As Boolean = True) As String
    
    Dim tmpString As String
    tmpString = String$(lengthInBytes / 2, 0)
    CopyMemoryStrict StrPtr(tmpString), srcPointer, lengthInBytes
    
    If trimNullChars Then
        ConvertUTF16PointerToVBString = Me.TrimNull(tmpString)
    Else
        ConvertUTF16PointerToVBString = tmpString
    End If
    
End Function

'Given an arbitrary pointer to a null-terminated CHAR or WCHAR run, measure the resulting string and copy the results
' into a VB string.
'
'For security reasons, if an upper limit of the string's length is known in advance (e.g. MAX_PATH), pass that limit
' via the optional maxLength parameter to avoid a buffer overrun.  This function has a hard-coded limit of 65k chars,
' a limit you can easily lift but which makes sense for PD.  If a string exceeds the limit (whether passed or
' hard-coded), *a string will still be created and returned*, but it will be clamped to the max length.
'
'If the string length is known in advance, and WCHARS are being used, please use the faster (and more secure)
' ConvertUTF16PointerToVBString function, above.
Friend Function ConvertCharPointerToVBString(ByVal srcPointer As Long, Optional ByVal stringIsUnicode As Boolean = True, Optional ByVal maxLength As Long = -1) As String
    
    'Check string length
    Dim strLength As Long
    If stringIsUnicode Then strLength = lstrlenW(srcPointer) Else strLength = lstrlenA(srcPointer)
    
    'Make sure the length/pointer isn't null
    If (strLength <= 0) Then
        ConvertCharPointerToVBString = ""
        Exit Function
    End If
    
    'Make sure the string's length is valid.
    Dim maxAllowedLength As Long
    If (maxLength = -1) Then maxAllowedLength = 65535 Else maxAllowedLength = maxLength
    If (strLength > maxAllowedLength) Then strLength = maxAllowedLength
    
    'Create the target string and copy the bytes over
    If stringIsUnicode Then
        ConvertCharPointerToVBString = String$(strLength, 0)
        CopyMemoryStrict StrPtr(ConvertCharPointerToVBString), srcPointer, strLength * 2
    Else
        ConvertCharPointerToVBString = SysAllocStringByteLen(srcPointer, strLength)
    End If
    
End Function

'Given a VB string, fill a byte array with matching UTF-8 data.  Returns TRUE if successful; FALSE otherwise
Friend Function StringToUTF8Bytes(ByRef srcString As String, ByRef dstUtf8() As Byte) As Boolean
    
    'Use WideCharToMultiByte() to calculate the required size of the final UTF-8 array.
    Dim lenUTF8 As Long
    lenUTF8 = WideCharToMultiByte(CP_UTF8, 0, StrPtr(srcString), Len(srcString), 0, 0, 0, 0)
    
    'If the returned length is 0, WideCharToMultiByte failed.  This typically only happens if totally invalid character combinations are found.
    If (lenUTF8 = 0) Then
        
        Debug.Print "StringToUTF8Bytes() failed because WideCharToMultiByte did not return a valid buffer length.)"
        Err.Raise Err.LastDllError, "StringToUTF8Bytes", "WideCharToMultiByte"
        StringToUTF8Bytes = False
    
    'The returned length is non-zero.  Prep a buffer, then process the bytes.
    Else
        
        'Prep a temporary byte buffer
        ReDim dstUtf8(0 To lenUTF8 - 1) As Byte
        
        'Use the API to perform the actual conversion
        lenUTF8 = WideCharToMultiByte(CP_UTF8, 0, StrPtr(srcString), Len(srcString), VarPtr(dstUtf8(0)), lenUTF8, 0, 0)
        
        'Make sure the conversion was successful.  (There is generally no reason for it to succeed when calculating a buffer length, only to
        ' fail here, but better safe than sorry.)
        If (lenUTF8 <> 0) Then
            StringToUTF8Bytes = True
        Else
            Debug.Print "StringToUTF8Bytes() failed because WideCharToMultiByte could not perform the conversion, despite returning a valid buffer length.)"
            Err.Raise Err.LastDllError, "StringToUTF8Bytes", "WideCharToMultiByte"
            StringToUTF8Bytes = False
        End If
        
    End If
    
End Function

'Given a byte array containing UTF-8 data, return the data as a VB string.  A custom length can also be specified;
' if it's missing, the full input array will be used.
Friend Function UTF8BytesToString(ByRef Utf8() As Byte, Optional ByVal customDataLength As Long = -1) As String
    
    'Use MultiByteToWideChar() to calculate the required size of the final string (e.g. UTF-8 expanded to VB's default wide character set).
    Dim lenWideString As Long
    If (customDataLength < 0) Then customDataLength = UBound(Utf8) + 1
    lenWideString = MultiByteToWideChar(CP_UTF8, 0, VarPtr(Utf8(0)), customDataLength, 0, 0)
    
    'If the returned length is 0, MultiByteToWideChar failed.  This typically only happens if totally invalid characters are found.
    If (lenWideString = 0) Then
        
        Debug.Print "UTF8BytesToString() failed because MultiByteToWideChar did not return a valid buffer length.)"
        Err.Raise Err.LastDllError, "UTF8BytesToString", "MultiByteToWideChar"
        UTF8BytesToString = ""
        
    'The returned length is non-zero.  Prep a buffer, then retrieve the bytes.
    Else
    
        'Prep a temporary string buffer
        UTF8BytesToString = String$(lenWideString, 0)
        
        'Use the API to perform the actual conversion
        lenWideString = MultiByteToWideChar(CP_UTF8, 0, VarPtr(Utf8(0)), customDataLength, StrPtr(UTF8BytesToString), lenWideString)
        
        'Make sure the conversion was successful.  (There is generally no reason for it to succeed when calculating a buffer length, only to
        ' fail here, but better safe than sorry.)
        If (lenWideString = 0) Then
            Debug.Print "UTF8BytesToString() failed because MultiByteToWideChar could not perform the conversion, despite returning a valid buffer length.)"
            Err.Raise Err.LastDllError, "UTF8BytesToString", "MultiByteToWideChar"
            UTF8BytesToString = ""
        End If
        
    End If
    
End Function

'Apply some basic heuristics to the first (n) bytes of a potentially UTF-8 source.
'
'This is based off a similar function by Dana Seaman, who noted an original source of http://www.geocities.co.jp/SilkRoad/4511/vb/utf8.htm
' I have modified the function to ignore invalid 5- and 6- byte extensions, which are not valid UTF-8, and to shorten the validation
' range as the original 2048 seems excessive.  (For a 24-byte sequence, the risk of a false positive is less than 1 in 1,000,000;
' see http://stackoverflow.com/questions/4520184/how-to-detect-the-character-encoding-of-a-text-file?lq=1.  False negative results have
' a higher probability, but several hundred characters should be enough to determine this, especially given the typical use-cases in PD.)
'
'For additional details on UTF-8 heuristics, see:
'  https://github.com/neitanod/forceutf8/blob/master/src/ForceUTF8/Encoding.php
'  http://www-archive.mozilla.org/projects/intl/UniversalCharsetDetection.html (very detailed)
Friend Function AreBytesUTF8(ByRef textBytes() As Byte, Optional ByVal verifyLength As Long = 512) As Boolean

    If verifyLength > 0 Then
    
        Dim pos As Long
        pos = 0
        
        Dim Utf8Size As Long, lIsUtf8 As Long, i As Long
        
        'If the requested verification length exceeds the size of the array, just search the entire array
        If verifyLength > UBound(textBytes) Then verifyLength = UBound(textBytes)
        
        'Scan through the byte array, looking for patterns specific to UTF-8
        Do While pos < verifyLength
        
            'If this is a standard ANSI value, it doesn't tell us anything useful - proceed to the next bytes
            If textBytes(pos) <= &H7F Then
                pos = pos + 1
            
            'If this value is a continuation byte (128-191), invalid byte (192-193), or Latin-1 identifier (194), we know
            ' the text is *not* UTF-8.  Exit now.
            ElseIf textBytes(pos) < &HC0 Then
                AreBytesUTF8 = False
                Exit Function
            
            'Other byte values are potential multibyte UTF-8 markers.  We will advance the pointer by a matching amount, and scan
            ' intermediary bytes to make sure they do not contain invalid markers.
            ElseIf (textBytes(pos) <= &HF4) Then
                
                'These special-range UTF-8 markers are used to represent multi-byte encodings.  Detect how many bytes are included
                ' in this character
                If (textBytes(pos) And &HF0) = &HF0 Then
                    Utf8Size = 3
                ElseIf (textBytes(pos) And &HE0) = &HE0 Then
                    Utf8Size = 2
                ElseIf (textBytes(pos) And &HC0) = &HC0 Then
                    Utf8Size = 1
                End If
                
                'If the position exceeds the length we are supposed to verify, exit now and rely on previous detection
                ' passes to return a yes/no result.
                If (pos + Utf8Size) >= verifyLength Then Exit Do
                
                'Scan the intermediary bytes of this character to ensure that no invalid markers are contained.
                For i = (pos + 1) To (pos + Utf8Size)
                    
                    'Valid UTF-8 continuation bytes must not exceed &H80
                    If Not ((textBytes(i) And &HC0) = &H80) Then
                        
                        'This is an invalid marker; exit immediately
                        AreBytesUTF8 = False
                        Exit Function
                        
                    End If
                    
                Next i
                
                'If we made it all the way here, all bytes in this multibyte set are valid.  Note that we've found at least one
                ' valid UTF-8 multibyte encoding, and carry on with the next character
                lIsUtf8 = lIsUtf8 + 1
                pos = pos + Utf8Size + 1
            
            'Byte values above 0xF4 are always invalid (http://en.wikipedia.org/wiki/UTF-8).  Exit immediately and report failure.
            Else
                AreBytesUTF8 = False
                Exit Function
            End If
            
        Loop
        
        'If we found at least one valid, multibyte UTF-8 sequence, return TRUE.  If we did not encounter such a sequence, then all
        ' characters fall within the ASCII range.  This is "indeterminate", and returning TRUE or FALSE is really a matter of preference.
        ' Default to whatever return you think is most likely.  (In our case, we assume ANSI, as files are likely coming from VB sources.)
        AreBytesUTF8 = (lIsUtf8 > 0)
        
    'If no validation length is passed, any heuristics are pointless - exit now.
    Else
        AreBytesUTF8 = False
        Exit Function
    End If
    
End Function

'Given an array of arbitrary bytes, perform a series of heuristics to perform a "best-guess" conversion to VB's internal DBCS string format.
'
'Currently supported formats include big- and little-endian UTF-16, UTF-8, DBCS, and ANSI variants.  Note that ANSI variants are *always*
' converted using the current codepage, as codepage heuristics are complicated and unwieldy.
'
'For best results, pass text directly from a file into this function, as BOMs can be very helpful when determining format.
'
'This function can optionally normalize line endings, but note that this is time-consuming.
'
'Finally, if you know the incoming string format in advance, it will be faster to perform your own format-specific conversion,
' as heuristics (particularly UTF-8 without BOM) can be time-consuming.
'
'RETURNS: TRUE if successful; FALSE otherwise.  Note that TRUE may not guarantee a correct string, especially if the incoming data
' is garbage, or if the format is unsupported or of some unknown ANSI codepage.
Friend Function ConvertUnknownBytesToString(ByRef srcBytes() As Byte, ByRef dstString As String, Optional ByVal forceWindowsLineEndings As Boolean = True) As Boolean
    
    On Error GoTo StringConversionFailed
    
    'There are a number of different ways to convert an arbitrary byte array to a string; this temporary string will be used to translate data
    ' between byte array and VB string as necessary.
    Dim tmpString As String
    
    'Start running some string encoding heuristics.  BOMs are checked first, as they're easiest to handle.  Note that no attempts are currently
    ' made to detect UTF-32, due to its extreme rarity.  (That said, heursitics for it are simple; see http://stackoverflow.com/questions/4520184/how-to-detect-the-character-encoding-of-a-text-file/4522251#4522251)
    
    'First, check for BOM 0xFFFE, which indicates little-endian UTF-16 (e.g. VB's internal format)
    If (srcBytes(0) = 255) And (srcBytes(1) = 254) Then
        
        'Cast the byte array straight into a string, then remove the BOM.
        tmpString = srcBytes
        dstString = Right$(tmpString, Len(tmpString) - 2)
        'Debug.Print "FYI: pdFSO.LoadTextFileAsString detected UTF-16 LE encoding for (" & srcFile & ")"
    
    'Next, check for big-endian UTF-16 (0xFEFF)
    ElseIf (srcBytes(0) = 254) And (srcBytes(1) = 255) Then
      
        'Swap all byte pairs in the incoming array
        Dim tmpSwap As Byte, i As Long
        
        For i = 0 To UBound(srcBytes) Step 2
            tmpSwap = srcBytes(i)
            srcBytes(i) = srcBytes(i + 1)
            srcBytes(i + 1) = tmpSwap
        Next i
        
        'Cast the newly ordered byte array straight into a string, then remove the BOM
        tmpString = srcBytes
        dstString = Right$(tmpString, Len(tmpString) - 2)
        'Debug.Print "FYI: pdUnicode.LoadTextFileAsString detected UTF-16 BE encoding for (" & srcFile & ")"
        
    'Next, check for UTF-8 BOM (0xEFBBBF).  This isn't common (UTF-8 doesn't require a BOM) but it's worth checking prior to diving into
    ' more complicated heuristics.
    ElseIf (srcBytes(0) = &HEF) And (srcBytes(1) = &HBB) And (srcBytes(2) = &HBF) Then
    
        'A helper function will convert the UTF-8 bytes for us; all we need to do is remove the BOM
        dstString = Mid$(UTF8BytesToString(srcBytes), 2)
        'Debug.Print "FYI: pdUnicode.LoadTextFileAsString detected UTF-8 encoding, via BOM, for (" & srcFile & ")"
        
    'All BOM checks failed.  Time to start running more complicated heuristics.
    Else
        
        'Check for UTF-8 data without a BOM.  The heuristics I use are pretty much perfect for avoiding false-positives, but there is
        ' a low risk of false-negatives.  The default character search (currently 512 octets) can be extended to reduce false-negative risk.
        If AreBytesUTF8(srcBytes) Then
            
            dstString = UTF8BytesToString(srcBytes)
            'Debug.Print "FYI: pdUnicode.LoadTextFileAsString is assuming UTF-8 encoding for (" & srcFile & ")"
        
        'If the bytes do not appear to be UTF-8, we could theoretically run one final ANSI check.  US-ANSI data falls into the [0, 127] range,
        ' exclusively, so it's easy to identify.  If, however, the file contains bytes outside this range, we're SOL, because extended bytes
        ' will vary according to the original creation locale (which we do not know).  In that case, we can't really do anything but use the
        ' current user locale and hope for the best, so rather than differentiate between these cases, I just do a forcible conversion using
        ' the current codepage anyway.
        Else
        
            dstString = StrConv(srcBytes, vbUnicode)
            'Debug.Print "FYI: pdUnicode.LoadTextFileAsString is unsure of this string's encoding.  Current user's codepage will be assumed."
            
        End If
        
    End If
    
    'If the caller is concerned about inconsistent line-endings, we can forcibly convert everything to vbCrLf.  This harms performance (as we
    ' need to cover both the CR-only case (OSX) and LF-only case (Linux/Unix)), but it ensures that any combination of linefeed characters
    ' are properly normalized against vbCrLf.
    If forceWindowsLineEndings Then
    
        'Force all existing vbCrLf instances to vbLf
        If InStr(1, dstString, vbCrLf, vbBinaryCompare) Then dstString = Replace$(dstString, vbCrLf, vbLf, , , vbBinaryCompare)
        
        'Force all existing vbCr instances to vbLf
        If InStr(1, dstString, vbCr, vbBinaryCompare) Then dstString = Replace$(dstString, vbCr, vbLf, , , vbBinaryCompare)
        
        'With everything normalized against vbLf, convert all vbLf instances to vbCrLf
        If InStr(1, dstString, vbLf, vbBinaryCompare) Then dstString = Replace$(dstString, vbLf, vbCrLf, , , vbBinaryCompare)
    
    End If
    
    ConvertUnknownBytesToString = True
    
    Exit Function
    
StringConversionFailed:

    Debug.Print "WARNING!  pdUnicode.convertUnknownBytesToString() failed with error " & Err.Number & ".  String conversion abandoned."
    ConvertUnknownBytesToString = False

End Function

'Convert a base-64 encoded string into a byte array, using standard Windows libraries.
' Returns TRUE if successful; FALSE otherwise.
'
'Thanks to vbForums user dilettante for the original version of this code (retrieved here: http://www.vbforums.com/showthread.php?514815-JPEG-Base-64&p=3186994&viewfull=1#post3186994)
Friend Function Base64Decode(ByRef dstArray() As Byte, ByVal strBase64 As String) As Boolean
    
    'Retrieve the necessary output buffer size.
    Dim lngOutLen As Long, dwActualUsed As Long
    If CryptStringToBinary(StrPtr(strBase64), Len(strBase64), CRYPT_STRING_BASE64, ByVal 0&, lngOutLen, 0&, dwActualUsed) <> 0 Then
        ReDim dstArray(lngOutLen - 1) As Byte
        Base64Decode = CBool(CryptStringToBinary(StrPtr(strBase64), Len(strBase64), CRYPT_STRING_BASE64, VarPtr(dstArray(0)), lngOutLen, 0&, dwActualUsed) <> 0)
    Else
        Base64Decode = False
    End If
    
End Function

'Return a Unicode-friendly copy of PD's command line params, pre-parsed into individual arguments.
' By default, the standard exe path entry is removed.  (This behavior can be toggled via the "removeExePath" parameter.)
' Returns: TRUE if argument count > 0; FALSE otherwise.
'          If TRUE is returned, dstStringStack is guaranteed to be initialized.
Friend Function CommandW(ByRef dstStringStack As pdStringStack, Optional ByVal removeExePath As Boolean = True) As Boolean
    
    Dim fullCmdLine As String
    
    'If inside the IDE, use VB's regular command-line; this allows test params set via Project Properties to still work
    If (Not g_IsProgramCompiled) Then
        fullCmdLine = Command$
    
    'When compiled, a true Unicode-friendly command line is returned
    Else
        fullCmdLine = Me.ConvertCharPointerToVBString(GetCommandLineW(), True)
    End If
    
    'Next, we want to pre-parse the string into individual arguments using WAPI
    If (Len(fullCmdLine) <> 0) Then
    
        Dim lPtr As Long, numArgs As Long
        lPtr = CommandLineToArgvW(StrPtr(fullCmdLine), numArgs)
        
        'lPtr now points to the first (of potentially many) string pointers, each one a command-line argument.
        ' We want to assume control over each string in turn, and add each to our destination pdStringStack object.
        If (dstStringStack Is Nothing) Then
            Set dstStringStack = New pdStringStack
        Else
            dstStringStack.ResetStack
        End If
        
        If (numArgs > 0) Then
        
            Dim i As Long, tmpString As String, tmpPtr As Long
            For i = 0 To numArgs - 1
                
                'Retrieve the next pointer
                CopyMemoryStrict VarPtr(tmpPtr), lPtr + 4 * i, 4&
                
                'Allocate a matching string (over which we have ownership)
                PutMem4 VarPtr(tmpString), SysAllocString(tmpPtr)
                
                'Conditionally add it to the string stack, depending on the removeExePath setting
                If removeExePath Then
                    If (InStr(1, tmpString, "PhotoDemon.exe", vbBinaryCompare) = 0) Then dstStringStack.AddString tmpString
                Else
                    dstStringStack.AddString tmpString
                End If
                
                'Free the temporary string
                tmpString = vbNullString
                
            Next
            
            CommandW = (dstStringStack.GetNumOfStrings <> 0)
        
        End If
        
        'Free the original arg pointer (which frees the corresponding system-controlled string references as well)
        ' Details here: https://msdn.microsoft.com/en-us/library/windows/desktop/bb776391%28v=vs.85%29.aspx?f=255&MSPPError=-2147217396
        If (lPtr <> 0) Then LocalFree lPtr
    
    End If
    
End Function

Friend Function ShrinkPathW(ByRef srcString As String, ByVal newMaxLength As Long) As String
    
    'Limit length to MAX_PATH
    If (newMaxLength > MAX_PATH) Then newMaxLength = MAX_PATH
    
    'This API is weird because regardless of original length, the incoming string must be, per MSDN,
    ' "A pointer to a null-terminated string of length MAX_PATH that contains the path to be altered."
    ' So we must copy the incoming string into a MAX_PATH buffer
    Dim tmpStringSrc As String, copyLength As Long
    tmpStringSrc = String$(MAX_PATH, 0)
    
    copyLength = Len(srcString)
    If (copyLength > MAX_PATH) Then copyLength = MAX_PATH
    CopyMemoryStrict StrPtr(tmpStringSrc), StrPtr(srcString), copyLength * 2
    
    'Now, prep an output buffer of size MAX_PATH
    Dim tmpStringDst As String
    tmpStringDst = String$(MAX_PATH, 0)
    
    'Use the API to shrink the path
    If (PathCompactPathEx(StrPtr(tmpStringDst), StrPtr(tmpStringSrc), newMaxLength + 1, 0&) <> 0) Then
        ShrinkPathW = Me.TrimNull(tmpStringDst)
    Else
        ShrinkPathW = tmpStringDst
    End If
    
End Function

'Apply some kind of remap conversion ("change case" in Latin languages) using WAPI.
' IMPORTANT: some LCMAP constants *are only available under Windows 7*, so be aware of which requests fail on earlier OSes.
Friend Function RemapString(ByRef srcString As String, ByVal remapType As PD_STRING_REMAP) As String
    
    'If the remap type is 0, do nothing
    If (remapType = PDRS_NONE) Then
        RemapString = srcString
        Exit Function
    End If
    
    'If the remap type is "titlecase" and we're on Vista or earlier, do nothing
    If (remapType = PDRS_TITLECASE_WIN7) And (Not cSysInfo.IsOSWin7OrLater) Then
        RemapString = srcString
        Exit Function
    End If
    
    'Convert the incoming remap type to an API equivalent
    Dim apiFlags As REMAP_STRING_API
    
    Select Case remapType
    
        Case PDRS_LOWERCASE
            apiFlags = LCMAP_LINGUISTIC_CASING Or LCMAP_LOWERCASE
        
        Case PDRS_UPPERCASE
            apiFlags = LCMAP_LINGUISTIC_CASING Or LCMAP_UPPERCASE
            
        Case PDRS_HIRAGANA
            apiFlags = LCMAP_HIRAGANA
            
        Case PDRS_KATAKANA
            apiFlags = LCMAP_KATAKANA
            
        Case PDRS_SIMPLE_CHINESE
            apiFlags = LCMAP_SIMPLIFIED_CHINESE
            
        Case PDRS_TRADITIONAL_CHINESE
            apiFlags = LCMAP_TRADITIONAL_CHINESE
            
        Case PDRS_TITLECASE_WIN7
            apiFlags = LCMAP_TITLECASE
    
    End Select
        
    'For Latin languages, the length of the new string shouldn't change, but with CJK languages, there are no guarantees.  As a failsafe,
    ' double the length of the temporary destination buffer.
    Dim dstString As String
    dstString = String$(Len(srcString) * 2, 0)
    
    'Use the Vista+ variant preferentially, as it has received additional updates versus the backward-compatible function.
    Dim apiSuccess As Boolean
    
    If cSysInfo.IsOSVistaOrLater Then
        
        If LCMapStringEx(0&, apiFlags, StrPtr(srcString), Len(srcString), StrPtr(dstString), Len(dstString), 0&, 0&, 0&) = 0 Then
            Debug.Print "WARNING!  LCMapStringEx() failed on /" & srcString & "/ and PD remap type " & remapType & "."
            apiSuccess = False
        Else
            apiSuccess = True
        End If
        
    Else
    
        If LCMapStringW(LOCALE_SYSTEM_DEFAULT, apiFlags, StrPtr(srcString), Len(srcString), StrPtr(dstString), Len(dstString)) = 0 Then
            Debug.Print "WARNING!  LCMapStringW() failed on /" & srcString & "/ and PD remap type " & remapType & "."
            apiSuccess = False
        Else
            apiSuccess = True
        End If
    
    End If
    
    'Because we use a huge destination buffer (as a failsafe), trailing null chars are inevitable.  Trim them before returning.
    If apiSuccess Then
        RemapString = TrimNull(dstString)
    Else
        RemapString = srcString
    End If
    
End Function

'When passing file and path strings to WAPI functions, we often have to pre-initialize them to some arbitrary buffer length
' (typically MAX_PATH).  When finished, the string needs to be trimmed to remove unused null chars.
Friend Function TrimNull(ByRef origString As String) As String
    
    'Start by double-checking that null chars actually exist in the string
    Dim nullPosition As Long
    nullPosition = InStr(origString, Chr$(0))
    
    'Remove null chars if present; otherwise, return a copy of the input string
    If (nullPosition <> 0) Then
       
        If nullPosition > 1 Then
            TrimNull = Left$(origString, nullPosition - 1)
        Else
            TrimNull = ""
        End If
    
    Else
       TrimNull = origString
    End If
    
End Function

Private Sub Class_Initialize()
    Set cSysInfo = New pdSystemInfo
End Sub
