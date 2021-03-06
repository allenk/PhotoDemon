Attribute VB_Name = "Loading"
'***************************************************************************
'General-purpose image and data import interface
'Copyright 2001-2017 by Tanner Helland
'Created: 4/15/01
'Last updated: 09/March/16
'Last update: total refactoring to prep for paint tools
'
'This module provides high-level "load" functionality for getting image files into PD.  There are a number of different ways to do this;
' for example, loading a user-facing image file is a horrifically complex affair, with lots of messy work involved in metadata parsing,
' UI prep, Undo/Redo stuff, and more.  Conversely, loading an image file as a resource or internal image can bypass a lot of those steps.
'
'Note that these high-level functions call into a number of lower-level functions inside the ImageImporter module, and potentially various
' plugin-specific interfaces (e.g. FreeImage).
'
'All source code in this file is licensed under a modified BSD license.  This means you may use the code in your own
' projects IF you provide attribution.  For more information, please visit http://photodemon.org/about/license/
'
'***************************************************************************

Option Explicit

'This function is used for loading a user-facing image (vs loading an internal PD image).  Loading a user-facing image involves
' a large amount of extra work (like metadata parsing) which we simply don't care about when loading internal resources.
'
'Note that this function will use one of several backends to load a given image; different filetypes are preferentially handled by
' different means, so portions of this function may call into external DLLs for parts of its functionality.  (The interaction between
' this function and various plugins is complex; I recommend studying the separate ImageImporter module for details.)
'
'INPUTS:
' 1) srcFile: fully qualified, absolute path to the source image.  Unicode is fully supported.
' 2) [optional] suggestedFilename: if loading an image from a temp file (e.g. clipboard, scanner), this value will be used in two places:
'                                  as the image's window caption, prior to first-save, and as the suggested filename at first-save.  As such,
'                                  make it user-friendly, e.g. "Clipboard image".
'                                  If this parameter is *not* supplied, the image's current filename will automatically be used.
' 3) [optional] addToRecentFiles: when a file loads successfully, we typically add it to the File > Recent Files list.  Some load operations,
'                                 like "Add new layer from file", or restoring a file from Autosave, don't easily fit into this paradigm.
'                                 This value tells the load engine to skip the "add to recent files" step.
' 4) [optional] suspendWarnings: at times, the caller may not want to have UI warnings raised for malformed or invalid files.  Batch processing
'                                and multi-image load are two examples.  If suspendWarnings = TRUE, any user-facing messages related to
'                                bad files will be suppressed.  (Note that the warnings can still be retrieved from debug logs, however.)
Public Function LoadFileAsNewImage(ByRef srcFile As String, Optional ByVal suggestedFilename As String = vbNullString, Optional ByVal addToRecentFiles As Boolean = True, Optional ByVal suspendWarnings As Boolean = False, Optional ByVal handleUIDisabling As Boolean = True) As Boolean
    
    '*** AND NOW, AN IMPORTANT MESSAGE ABOUT DOEVENTS ***
    
    'Normally, PD avoids DoEvents for all the obvious reasons.  This function is a stark exception to that rule.  Why?
    
    'While this function stays busy loading the image in question, the ExifTool plugin runs asynchronously, parsing image metadata
    ' and forwarding the results to a ShellPipe instance on PD's primary form.  By using DoEvents throughout this function, we periodically
    ' yield control to that ShellPipe instance, which allows it to clear stdout so ExifTool can continue pushing metadata through.
    ' (If we don't do this, ExifTool will freeze when stdout fills its buffer, which is not just possible but *probable*, given how much
    ' metadata the average JPEG contains.)
    
    'That said, please note that a LOT of precautions have been taken to make sure DoEvents doesn't cause reentry and other issues.
    ' Do *not* mimic this behavior in your own code unless you understand the repercussions involved!
    
    '*** END MESSAGE ***
    
    'If debug mode is active, image loading is a place where many things can go wrong - bad files, corrupt formats, heavy RAM usage,
    ' incompatible color formats, and about a bazillion other problems.  As such, this function dumps a *lot* of information to
    ' the debug log, to help narrow down problems.
    #If DEBUGMODE = 1 Then
        Dim startTime As Currency
        VBHacks.GetHighResTime startTime
        pdDebug.LogAction "Image load requested for """ & GetFilename(srcFile) & """.  Baseline memory reading:"
        pdDebug.LogAction "", PDM_MEM_REPORT
    #End If
    
    'Display a busy cursor
    If handleUIDisabling Then
        Message "Loading image..."
        Processor.MarkProgramBusyState True, True
    End If
    
    '*************************************************************************************************************************************
    ' Prepare all variables related to image loading
    '*************************************************************************************************************************************
    
    'Normally, an unsuccessful load just causes the function to exit prematurely, but sometimes we can't detect an unsuccessful load
    ' until deep into the load process.  When this happens, we may need to roll-back things like memory allocations, so we check success
    ' state quite a few times throughout the function.
    Dim loadSuccessful As Boolean: loadSuccessful = False
    
    'This function is 100% Unicode-compatible, thanks to pdFSO.  It must be used for all file-level interactions.
    Dim cFile As pdFSO
    Set cFile = New pdFSO
    
    'Some behavior varies based on the image decoding engine used.  PD uses a fairly complex cascading system for image decoders;
    ' if one fails, we continue trying alternates until either the load succeeds, or all known decoders have been exhausted.
    Dim decoderUsed As PD_IMAGE_DECODER_ENGINE: decoderUsed = PDIDE_FAILEDTOLOAD
    
    'Some image formats (like TIFF, animated GIF, icons) support the notion of "multiple pages".  PD can detect such images,
    ' and depending on user input, handle the file a few different ways.
    Dim imageHasMultiplePages As Boolean: imageHasMultiplePages = False
    Dim numOfPages As Long: numOfPages = 0
    
    'We now have one last tedious check to perform: making sure the file actually exists!
    If (Not cFile.FileExist(srcFile)) Then
        If handleUIDisabling Then Processor.MarkProgramBusyState False, True
        If (Not suspendWarnings) Then
            Message "File not found: %1", srcFile
            PDMsgBox "Unfortunately, the image '%1' could not be found." & vbCrLf & vbCrLf & "If this image was originally located on removable media (DVD, USB drive, etc), please re-insert or re-attach the media and try again.", vbApplicationModal + vbExclamation + vbOKOnly, "File not found", srcFile
        End If
        LoadFileAsNewImage = False
        Exit Function
    End If
    
    'Now we get into the meat-and-potatoes portion of this sub.  Main segments are labeled by large, asterisk-separated bars.
    ' These segments generally describe a group of tasks with related purpose, and many of these tasks branch out into other modules.
    
        
    '*************************************************************************************************************************************
    ' If the image being loaded is a primary image (e.g. one opened normally), prepare a blank pdImage object to receive it
    '*************************************************************************************************************************************
    
    'To prevent re-entry problems, forcibly disable the main form before proceeding further.  Note that any criteria that result in
    ' a premature exit from this function *MUST* reenable the form manually!
    If handleUIDisabling Then FormMain.Enabled = False
    
    'PD has a three-tiered management system for images:
    ' 1) pdImage object: the main object, which holds a stack of one or more layers, and a bunch of image-level data (like filename)
    ' 2) pdLayer object: a layer object which holds a stack of one or more DIBs, and a bunch of layer-level data (like blendmode)
    ' 3) pdDIB object: eventually this will be retitled as pdSurface, as it may not be a DIB, but at present, a single grid of pixels
    
    'Different parts of the load process interact with different levels of our target pdImage object.  If loading a PDI file
    ' (PhotoDemon's native format), multiple layers and DIBs will be loaded and processed for a singular pdImage object.
    
    'Anyway, in the future, I'd like to avoid referencing the pdImages collection directly, and instead use helper functions.
    ' To facilitate this switch, I've written this function to use generic "targetImage" and "targetDIB" objects.  (targetLayer isn't
    ' as important, as most image files only consist of a single default layer inside targetImage.)
    
    'Retrieve an empty, default pdImage object.  Note that this object does not yet exist inside the main pdImages collection,
    ' so we cannot refer to it by ordinal.
    Dim targetImage As pdImage
    CanvasManager.GetDefaultPDImageObject targetImage
    
    'Normally, we don't assign an ID value to an image until we actually add it to the master pdImages collection.  However, some tasks
    ' (like retrieving metadata asynchronously) require an ID so we can synchronize incoming data post-load.  Give the target image
    ' a provisional image ID; this ID will become its formal ID only if it's loaded successfully.
    targetImage.imageID = CanvasManager.GetProvisionalImageID()
    
    'Next, create a blank target layer and target DIB.  If all of these are loaded correctly, we'll eventually assemble them
    ' into the targetImage object.
    Dim newLayerID As Long
    newLayerID = targetImage.CreateBlankLayer
    
    Dim targetDIB As pdDIB
    Set targetDIB = New pdDIB
    
    '*************************************************************************************************************************************
    ' Make a best guess at the incoming image's format
    '*************************************************************************************************************************************
    
    #If DEBUGMODE = 1 Then
        pdDebug.LogAction "Determining filetype..."
    #End If
    
    If Not (targetImage Is Nothing) Then targetImage.SetOriginalFileFormat FIF_UNKNOWN
    
    Dim srcFileExtension As String
    srcFileExtension = UCase$(GetExtension(srcFile))
    
    Dim internalFormatID As PD_IMAGE_FORMAT
    internalFormatID = CheckForInternalFiles(srcFileExtension)
    
    'Files with a PD-specific format have now been specially marked, while generic files (JPEG, PNG, etc) have not.
    
    '*************************************************************************************************************************************
    ' If the ExifTool plugin is available and this is a non-PD-specific file, initiate a separate thread for metadata extraction
    '*************************************************************************************************************************************
    If g_ExifToolEnabled And (internalFormatID <> PDIF_PDI) And (internalFormatID <> PDIF_RAWBUFFER) Then
        
        #If DEBUGMODE = 1 Then
            pdDebug.LogAction "Starting separate metadata extraction thread..."
        #End If
            
        StartMetadataProcessing srcFile, targetImage
        
    End If
    
    '*************************************************************************************************************************************
    ' Split handling into two groups: internal PD formats vs generic external formats
    '*************************************************************************************************************************************
    
    Dim freeImage_Return As PD_OPERATION_OUTCOME
    
    If (internalFormatID = FIF_UNKNOWN) Then
    
        'Note that FreeImage may raise additional dialogs (e.g. for HDR/RAW images), so it does not return a binary pass/fail.
        ' If the function fails due to user cancellation, we will suppress subsequent error message boxes.
        loadSuccessful = ImageImporter.CascadeLoadGenericImage(srcFile, targetImage, targetDIB, freeImage_Return, decoderUsed, imageHasMultiplePages, numOfPages)
        
    'PD-specific files use their own load function, which bypasses a lot of tedious format-detection heuristics
    Else
    
        loadSuccessful = ImageImporter.CascadeLoadInternalImage(internalFormatID, srcFile, targetImage, targetDIB, freeImage_Return, decoderUsed, imageHasMultiplePages, numOfPages)
    
        #If DEBUGMODE = 1 Then
            If (Not loadSuccessful) Then
                pdDebug.LogAction "WARNING!  LoadFileAsNewImage failed on an internal file; all engines failed to handle " & srcFile & " correctly."
            End If
        #End If
        
    End If
    
    'Eventually, the user may choose to save this image in a new format, but for now, the original and current formats are identical
    targetImage.SetCurrentFileFormat targetImage.GetOriginalFileFormat
    
    #If DEBUGMODE = 1 Then
        pdDebug.LogAction "Format-specific parsing complete.  Running a few failsafe checks on the new pdImage object..."
    #End If
    
    'Because ExifTool is sending us data in the background, we must periodically yield for metadata piping.
    If (ExifTool.IsMetadataPipeActive) Then DoEvents
    
    
    '*************************************************************************************************************************************
    ' Run a few failsafe checks to confirm that the image data was loaded successfully
    '*************************************************************************************************************************************
    
    If loadSuccessful And (targetDIB.GetDIBWidth > 0) And (targetDIB.GetDIBHeight > 0) And (Not (targetImage Is Nothing)) Then
        
        #If DEBUGMODE = 1 Then
            pdDebug.LogAction "Debug note: image load appeared to be successful.  Summary forthcoming."
        #End If
        
        '*************************************************************************************************************************************
        ' If the loaded image was in PDI format (PhotoDemon's internal format), skip a number of additional processing steps.
        '*************************************************************************************************************************************
        
        If (internalFormatID <> PDIF_PDI) Then
            
            'While inside this section of the load process, you'll notice a consistent trend regarding DOEVENTS.  If you haven't already,
            ' now is a good time to scroll up to the top of this function to read the IMPORTANT NOTE!
            
            '*************************************************************************************************************************************
            ' If the image contains an embedded ICC profile, apply it now
            '*************************************************************************************************************************************
            
            If ImageImporter.ApplyPostLoadICCHandling(targetDIB) Then DoEvents
            
            '*************************************************************************************************************************************
            ' If the incoming image is 24bpp, convert it to 32bpp.  (PD assumes an available alpha channel for all layers.)
            '*************************************************************************************************************************************
            
            If ImageImporter.ForceTo32bppMode(targetDIB) Then DoEvents
            
            '*************************************************************************************************************************************
            ' The target DIB has been loaded successfully, so copy its contents into the main layer of the targetImage
            '*************************************************************************************************************************************
                
            'Besides a source DIB, the "add new layer" function also wants a name for the new layer.  Create one now.
            Dim newLayerName As String
            newLayerName = Layers.GenerateInitialLayerName(srcFile, suggestedFilename, imageHasMultiplePages, targetImage, targetDIB)
            
            'Create the new layer in the target image, and pass our created name to it
            targetImage.GetLayerByID(newLayerID).InitializeNewLayer PDL_IMAGE, newLayerName, targetDIB, CBool(imageHasMultiplePages)
            targetImage.UpdateSize
            
            DoEvents
            
        '/End specialized handling for non-PDI files
        End If
        
        'Any remaining attributes of interest should be stored in the target image now
        targetImage.imgStorage.AddEntry "OriginalFileSize", cFile.FileLenW(srcFile)
        
        'We've now completed the bulk of the image load process.  In nightly builds, dump a bunch of image-related data out to file;
        ' such data is invaluable when tracking down bugs.
        #If DEBUGMODE = 1 Then
        
            pdDebug.LogAction "~ Summary of image """ & GetFilename(srcFile) & """ follows ~", , True
            pdDebug.LogAction vbTab & "Image ID: " & targetImage.imageID, , True
            
            Select Case decoderUsed
                
                Case PDIDE_INTERNAL
                    pdDebug.LogAction vbTab & "Load engine: Internal PhotoDemon decoder", , True
                
                Case PDIDE_FREEIMAGE
                    pdDebug.LogAction vbTab & "Load engine: FreeImage plugin", , True
                
                Case PDIDE_GDIPLUS
                    pdDebug.LogAction vbTab & "Load engine: GDI+", , True
                
                Case PDIDE_VBLOADPICTURE
                    pdDebug.LogAction vbTab & "Load engine: VB's LoadPicture() function", , True
                
            End Select
            
            pdDebug.LogAction vbTab & "Detected format: " & g_ImageFormats.GetInputFormatDescription(g_ImageFormats.GetIndexOfInputPDIF(targetImage.GetOriginalFileFormat)), , True
            pdDebug.LogAction vbTab & "Image dimensions: " & targetImage.Width & "x" & targetImage.Height, , True
            pdDebug.LogAction vbTab & "Image size (original file): " & Format(CStr(targetImage.imgStorage.GetEntry_Long("OriginalFileSize")), "###,###,###,###") & " Bytes", , True
            pdDebug.LogAction vbTab & "Image size (as loaded, approximate): " & Format(CStr(targetImage.EstimateRAMUsage), "###,###,###,###") & " Bytes", , True
            pdDebug.LogAction vbTab & "Original color depth: " & targetImage.GetOriginalColorDepth, , True
            pdDebug.LogAction vbTab & "ICC profile embedded: " & targetDIB.ICCProfile.HasICCData, , True
            pdDebug.LogAction vbTab & "Multiple pages embedded: " & CStr(imageHasMultiplePages), , True
            pdDebug.LogAction vbTab & "Number of layers: " & targetImage.GetNumOfLayers, , True
            pdDebug.LogAction "~ End of image summary ~", , True
            
        #End If
        
        '*************************************************************************************************************************************
        ' Generate all relevant pdImage attributes tied to the source file (like the image's name and save state)
        '*************************************************************************************************************************************
        
        'First, see if this image is being restored from PD's "autosave" engine.  Autosaved images require special handling, because their
        ' state must be reconstructed from whatever bits we can dredge up from the temp file.
        If srcFileExtension = "PDTMP" Then
            ImageImporter.SyncRecoveredAutosaveImage srcFile, targetImage
        Else
            ImageImporter.GenerateExtraPDImageAttributes srcFile, targetImage, suggestedFilename
        End If
        
        'Because ExifTool is sending us data in the background, we periodically yield for metadata piping.
        If (ExifTool.IsMetadataPipeActive) Then DoEvents
            
            
        '*************************************************************************************************************************************
        ' If this is a primary image, update all relevant UI elements (image size display, custom form icon, etc)
        '*************************************************************************************************************************************
        
        #If DEBUGMODE = 1 Then
            pdDebug.LogAction "Finalizing image details..."
        #End If
        
        'The finalized pdImage object is finally worthy of being added to the master PD collection.  Note that this function will
        ' automatically update g_CurrentImage to point to the new image.
        CanvasManager.AddImageToMasterCollection targetImage
        
        ImageImporter.ApplyPostLoadUIChanges srcFile, targetImage, addToRecentFiles
        
        'Because ExifTool is sending us data in the background, we periodically yield for metadata piping.
        If (ExifTool.IsMetadataPipeActive) Then DoEvents
        
            
        '*************************************************************************************************************************************
        ' If the just-loaded image was in a multipage format (icon, animated GIF, multipage TIFF), perform a few extra checks.
        '*************************************************************************************************************************************
        
        'Before continuing on to the next image (if any), see if the just-loaded image contains multiple pages within the file.
        ' If it does, load each page into its own layer.
        If imageHasMultiplePages Then
            
            'TODO: deal with prompt options here!
            
            'Add a flag to this pdImage object noting that the multipage loading path *was* utilized.
            targetImage.imgStorage.AddEntry "MultipageImportActive", True
            
            'We now have several options for loading the remaining pages in this file.
            
            'For most images, the easiest path would be to keep calling the standard FI_LoadImage function(), passing it updated
            ' page numbers as we go.  This ensures that all the usual fallbacks and detailed edge-case handling (like ICC profiles
            ' that vary by page) are handled correctly.
            '
            'However, it also means that the source file is loaded/unloaded on each frame, because the FreeImage load function
            ' was never meant to be used like this.  This isn't a problem for images with a few pages, but if the image is large
            ' and/or if it has tons of frames (like a length animated GIF), we could be here awhile.
            '
            'As of 7.0, a better solution exists: ask FreeImage to cache the source file, and keep it cached until all frames
            ' have been loaded.  This is *way* faster, and it also lets us bypass a bunch of per-file validation checks
            ' (since we already know the source file is okay).
            loadSuccessful = Plugin_FreeImage.FinishLoadingMultipageImage(srcFile, targetDIB, numOfPages, , targetImage, , suggestedFilename)
            
            'As a convenience, make all but the first page/frame/icon invisible when the source is a GIF or ICON.
            ' (TIFFs don't require this, as all pages are typically the same size.)
            If (targetImage.GetNumOfLayers > 1) And (targetImage.GetOriginalFileFormat <> PDIF_TIFF) Then
                Dim pageTracker As Long
                For pageTracker = 1 To targetImage.GetNumOfLayers - 1
                    targetImage.GetLayerByIndex(pageTracker).SetLayerVisibility False
                Next pageTracker
                targetImage.SetActiveLayerByIndex 0
            End If
            
            'With all pages/frames/icons successfully loaded, redraw the main viewport
            ViewportEngine.Stage1_InitializeBuffer targetImage, FormMain.mainCanvas(0), VSR_ResetToZero
            
        'Add a flag to this pdImage object noting that the multipage loading path was *not* utilized.
        Else
            targetImage.imgStorage.AddEntry "MultipageImportActive", False
        End If
            
        '*************************************************************************************************************************************
        ' Hopefully metadata processing has finished, but if it hasn't, start a timer on the main form, which will wait for it to complete.
        '*************************************************************************************************************************************
        
        'Ask the metadata handler if it has finished parsing the image
        If g_ExifToolEnabled And (decoderUsed <> PDIDE_INTERNAL) Then
            
            'Some tools may have already stopped to load metadata
            If (Not targetImage.imgMetadata.HasMetadata) Then
            
                If ExifTool.IsMetadataFinished Then
                    #If DEBUGMODE = 1 Then
                        pdDebug.LogAction "Metadata retrieved successfully."
                    #End If
                    targetImage.imgMetadata.LoadAllMetadata ExifTool.RetrieveMetadataString, targetImage.imageID
                Else
                    #If DEBUGMODE = 1 Then
                        pdDebug.LogAction "Metadata parsing hasn't finished; switching to asynchronous wait mode..."
                    #End If
                    FormMain.StartMetadataTimer
                End If
            
            End If
    
            'Next, retrieve any specific metadata-related entries that may be useful to further processing, like image resolution
            Dim xResolution As Double, yResolution As Double
            If targetImage.imgMetadata.GetResolution(xResolution, yResolution) Then
                targetImage.SetDPI xResolution, yResolution
            End If
        
        End If
            
            
        '*************************************************************************************************************************************
        ' As of 2014, the new Undo/Redo engine requires a base pdImage copy as the starting point for Undo/Redo diffs.
        '*************************************************************************************************************************************
        
        'If this is a primary image, force an immediate Undo/Redo write to file.  This serves multiple purposes: it is our
        ' baseline for calculating future Undo/Redo diffs, and it can be used to recover the original file if something
        ' goes wrong before the user performs a manual save (e.g. AutoSave).
        '
        '(Note that all Undo behavior is disabled during batch processing, to improve performance, so we can skip this step.)
        If (MacroStatus <> MacroBATCH) Then
            
            #If DEBUGMODE = 1 Then
                pdDebug.LogAction "Creating initial auto-save entry (this may take a moment)..."
            #End If
            
            targetImage.undoManager.CreateUndoData g_Language.TranslateMessage("Original image"), "", UNDO_EVERYTHING
            
        End If
            
            
        '*************************************************************************************************************************************
        ' Image loaded successfully.  Carry on.
        '*************************************************************************************************************************************
        
        loadSuccessful = True
        
        'In debug mode, note the new memory baseline, post-load
        #If DEBUGMODE = 1 Then
            pdDebug.LogAction "New memory report after loading image """ & GetFilename(srcFile) & """:"
            pdDebug.LogAction "", PDM_MEM_REPORT
            
            'Also report an estimated memory delta, based on the pdImage object's self-reported memory usage.
            ' This provides a nice baseline for making sure PD's memory usage isn't out of whack for a given image.
            pdDebug.LogAction "(FYI, expected delta was approximately " & Format(CStr(targetImage.EstimateRAMUsage \ 1000), "###,###,###,###") & " K)"
        #End If
    
    'This ELSE block is hit when the image fails post-load verification checks.  Treat the load as unsuccessful.
    Else
    
        loadSuccessful = False
        
        'Deactivate the (now useless) pdImage and pdDIB objects, which will forcibly unload whatever resources they may have claimed
        If (Not targetDIB Is Nothing) Then Set targetDIB = Nothing
        
        If (Not targetImage Is Nothing) Then
            targetImage.FreeAllImageResources
            Set targetImage = Nothing
        End If
    
    End If
    
    '*************************************************************************************************************************************
    ' As all images have now loaded, re-enable the main form
    '*************************************************************************************************************************************
    
    'Synchronize all interface elements to match the newly loaded image(s)
    If handleUIDisabling Then Interface.SyncInterfaceToCurrentImage
    
    'Synchronize any non-destructive settings to the currently active layer
    If (handleUIDisabling And loadSuccessful) Then
        Processor.SyncAllGenericLayerProperties pdImages(g_CurrentImage).GetActiveLayer
        Processor.SyncAllNDFXLayerProperties pdImages(g_CurrentImage).GetActiveLayer
        Processor.SyncAllTextLayerProperties pdImages(g_CurrentImage).GetActiveLayer
    End If
    
    '*************************************************************************************************************************************
    ' Before finishing, display any relevant load problems (missing files, invalid formats, etc)
    '*************************************************************************************************************************************
    
    'Restore the screen cursor if necessary
    If handleUIDisabling Then Processor.MarkProgramBusyState False, True, CBool(g_OpenImageCount > 1)
        
    'Report success/failure back to the user
    LoadFileAsNewImage = CBool(loadSuccessful And (Not targetImage Is Nothing))
    
    If LoadFileAsNewImage Then
        Message "Image loaded successfully."
    Else
        If (MacroStatus <> MacroBATCH) And (Not suspendWarnings) And (freeImage_Return <> PD_FAILURE_USER_CANCELED) Then
            Message "Failed to load %1", srcFile
            PDMsgBox "Unfortunately, PhotoDemon was unable to load the following image:" & vbCrLf & vbCrLf & "%1" & vbCrLf & vbCrLf & "Please use another program to save this image in a generic format (such as JPEG or PNG) before loading it.  Thanks!", vbExclamation + vbOKOnly + vbApplicationModal, "Image import failed", srcFile
        End If
    End If
    
    #If DEBUGMODE = 1 Then
        pdDebug.LogAction "Image loaded in " & Format$(VBHacks.GetTimerDifferenceNow(startTime) * 1000, "#0") & " ms"
    #End If
        
End Function

'Quick and dirty function for loading an image file to a containing DIB.  This function provides none of the extra scans or features
' that the more advanced LoadFileAsNewImage does; instead, it is assumed that the calling function will handle any extra work.
' (Note that things like metadata will not be processed *at all* for the image file.)
'
'That said, FreeImage/GDI+ are still used intelligently, so this function should reflect PD's full capacity for image format support.
'
'The function will return TRUE if successful; detailed load information is not available past that.
Public Function QuickLoadImageToDIB(ByVal imagePath As String, ByRef targetDIB As pdDIB, Optional ByVal applyUIChanges As Boolean = True, Optional ByVal displayMessagesToUser As Boolean = True, Optional ByVal processColorProfiles As Boolean = True, Optional ByVal suppressDebugData As Boolean = False) As Boolean
    
    Dim loadSuccessful As Boolean: loadSuccessful = False
    
    'Even though this function is designed to operate as quickly as possible, some images may take a long time to load.
    If applyUIChanges Then
        Processor.MarkProgramBusyState True, True
    End If
    
    'Before attempting to load an image, make sure it exists
    Dim cFile As pdFSO
    Set cFile = New pdFSO
    
    If (Not cFile.FileExist(imagePath)) Then
        If displayMessagesToUser Then PDMsgBox "Unfortunately, the image '%1' could not be found." & vbCrLf & vbCrLf & "If this image was originally located on removable media (DVD, USB drive, etc), please re-insert or re-attach the media and try again.", vbApplicationModal + vbExclamation + vbOKOnly, "File not found", imagePath
        QuickLoadImageToDIB = False
        If applyUIChanges Then Processor.MarkProgramBusyState False, True
        Exit Function
    End If
        
    'Prepare a dummy pdImage object, which some external functions may require
    Dim tmpPDImage As pdImage
    Set tmpPDImage = New pdImage
    
    'Determine the most appropriate load function for this image's format (FreeImage, GDI+, or VB's LoadPicture).  Note that FreeImage does not
    ' return a generic pass/fail value.
    Dim freeImageReturn As PD_OPERATION_OUTCOME
    freeImageReturn = PD_FAILURE_GENERIC
    
    'Start by stripping the extension from the file path
    Dim FileExtension As String
    FileExtension = UCase$(cFile.GetFileExtension(imagePath))
    loadSuccessful = False
    
    'Depending on the file's extension, load the image using the most appropriate image decoding routine
    Select Case FileExtension
    
        'PhotoDemon's custom file format must be handled specially (as obviously, FreeImage and GDI+ won't handle it!)
        Case "PDI"
        
            'PDI images require zLib, and are only loaded via a custom routine (obviously, since they are PhotoDemon's native format)
            loadSuccessful = LoadPhotoDemonImage(imagePath, targetDIB, tmpPDImage)
            
            'Retrieve a copy of the fully composited image
            tmpPDImage.GetCompositedImage targetDIB
            
        'TMPDIB files are raw pdDIB objects dumped directly to file.  In some cases, this is faster and easier for PD than wrapping
        ' the pdDIB object inside a pdPackage layer (especially if this function is going to be used, since we're just going to
        ' decode the saved file into a pdDIB anyway).
        Case "TMPDIB", "PDTMPDIB"
            loadSuccessful = LoadRawImageBuffer(imagePath, targetDIB, tmpPDImage)
            
        'TMP files are internal PD temp files generated from a wide variety of use-cases (Clipboard is one example).  These are
        ' typically in BMP format, but this is not contractual.  A standard cascade of load functions is used.
        Case "TMP"
            If g_ImageFormats.FreeImageEnabled Then loadSuccessful = CBool(FI_LoadImage_V5(imagePath, targetDIB, , False, , suppressDebugData) = PD_SUCCESS)
            If g_ImageFormats.GDIPlusEnabled And (Not loadSuccessful) Then loadSuccessful = LoadGDIPlusImage(imagePath, targetDIB)
            If (Not loadSuccessful) Then loadSuccessful = LoadVBImage(imagePath, targetDIB)
            If (Not loadSuccessful) Then loadSuccessful = LoadRawImageBuffer(imagePath, targetDIB, tmpPDImage)
            
        'PDTMP files are custom PD-format files saved ONLY during Undo/Redo or Autosaving.  As such, they have some weirdly specific
        ' parsing criteria during the master load function, but for quick-loading, we can simply grab the raw image buffer portion.
        Case "PDTMP"
            loadSuccessful = LoadRawImageBuffer(imagePath, targetDIB, tmpPDImage)
            
        'All other formats follow a set pattern: try to load them via FreeImage (if it's available), then GDI+, then finally
        ' VB's internal LoadPicture function.
        Case Else
            
            'If FreeImage is available, use it to try and load the image.
            If g_ImageFormats.FreeImageEnabled Then
                freeImageReturn = FI_LoadImage_V5(imagePath, targetDIB, 0, False, , suppressDebugData)
                loadSuccessful = CBool(freeImageReturn = PD_SUCCESS)
            End If
                
            'If FreeImage fails for some reason, offload the image to GDI+
            If (Not loadSuccessful) And g_ImageFormats.GDIPlusEnabled Then loadSuccessful = LoadGDIPlusImage(imagePath, targetDIB)
            
            'If both FreeImage and GDI+ failed, give the image one last try with VB's LoadPicture - UNLESS the image is a WMF or EMF,
            ' which can cause LoadPicture to experience a silent fail, thus bringing down the entire program.
            If (Not loadSuccessful) And ((FileExtension <> "EMF") And (FileExtension <> "WMF")) Then loadSuccessful = LoadVBImage(imagePath, targetDIB)
                    
    End Select
    
    'Sometimes, our image load functions will think the image loaded correctly, but they will return a blank image.  Check for
    ' non-zero width and height before continuing.
    If (targetDIB Is Nothing) Then
        loadSuccessful = False
    Else
        If (targetDIB.GetDIBWidth = 0) Or (targetDIB.GetDIBHeight = 0) Then loadSuccessful = False
    End If
    
    If (Not loadSuccessful) Then
        
        'Only display an error dialog if the import wasn't canceled by the user
        If displayMessagesToUser Then
            If (freeImageReturn <> PD_FAILURE_USER_CANCELED) Then
                Message "Failed to load %1", imagePath
                PDMsgBox "Unfortunately, PhotoDemon was unable to load the following image:" & vbCrLf & vbCrLf & "%1" & vbCrLf & vbCrLf & "Please use another program to save this image in a generic format (such as JPEG or PNG) before loading it into PhotoDemon.  Thanks!", vbExclamation + vbOKOnly + vbApplicationModal, "Image Import Failed", imagePath
            Else
                Message "Layer import canceled."
            End If
        End If
        
        'Deactivate the (now useless) DIB and parent object
        If (Not tmpPDImage Is Nothing) Then
            tmpPDImage.FreeAllImageResources
            Set tmpPDImage = Nothing
        End If
        
        If (Not targetDIB Is Nothing) Then Set targetDIB = Nothing
        
        'Re-enable the main interface
        If applyUIChanges Then Processor.MarkProgramBusyState False, True
        
        'Exit with failure status
        QuickLoadImageToDIB = False
        
        Exit Function
        
    End If
    
    'If the image contained an embedded ICC profile, apply it now.
    If processColorProfiles Then ImageImporter.ApplyPostLoadICCHandling targetDIB
    
    'Restore the main interface
    If applyUIChanges Then Processor.MarkProgramBusyState False, True

    'If we made it all the way here, the image file was loaded successfully!
    QuickLoadImageToDIB = True

End Function

'Given a source filename's extension, return the estimated filetype (as an FIF_ constant) if the image format is specific to PD.
' This lets us quickly redirect PD-specific files to our own internal functions.
Private Function CheckForInternalFiles(ByRef srcFileExtension As String) As PD_IMAGE_FORMAT
    
    CheckForInternalFiles = FIF_UNKNOWN
    
    Select Case srcFileExtension
    
        'Well-formatted PDI files
        Case "PDI", "PDTMP"
            CheckForInternalFiles = PDIF_PDI
            
        'TMPDIB files are raw pdDIB objects dumped directly to file.  In some cases, this is faster and easier for PD than wrapping
        ' the pdDIB object inside a pdPackage layer (e.g. during clipboard interactions, since we start with a raw pdDIB object
        ' after selections and such are applied to the base layer/image, so we may as well just use the raw pdDIB data we've cached).
        Case "TMPDIB", "PDTMPDIB"
            CheckForInternalFiles = PDIF_RAWBUFFER
            
        'Straight TMP files are internal files (BMP, typically) used by PhotoDemon.  These are typically older conversion functions,
        ' created before PDIs were finalized.
        Case "TMP"
            CheckForInternalFiles = PDIF_TMPFILE
            
    End Select
    
    'Any other formats will be dealt with by PD's standard cascade of load functions.

End Function

'Want to load a whole bunch of image sources at once?  Use this function to do so.  While helpful, note that it comes with some caveats:
' 1) The only supported sources are absolute filenames.
' 2) You lose the ability to assign custom titles to incoming images.  Titles will be auto-assigned based on their filenames.
' 3) You won't receive detailed success/failure information on each file.  Instead, this function will return TRUE if it was able to load
'    at least one image successfully.  If you want per-file success/fail results, call LoadFileAsNewImage manually from your own loop.
Public Function LoadMultipleImageFiles(ByRef srcList As pdStringStack, Optional ByVal updateRecentFileList As Boolean = True) As Boolean

    If (Not srcList Is Nothing) Then
        
        'A lot can go wrong when loading image files.  This function will track failures and notify the user post-load.
        Dim numFailures As Long, numSuccesses As Long
        Dim brokenFiles As String
        
        Processor.MarkProgramBusyState True, True
        
        Dim tmpFilename As String
        Do While srcList.PopString(tmpFilename)
            If LoadFileAsNewImage(tmpFilename, , updateRecentFileList, True, False) Then
                numSuccesses = numSuccesses + 1
            Else
                If (Len(tmpFilename) <> 0) Then
                    numFailures = numFailures + 1
                    brokenFiles = brokenFiles & GetFilename(tmpFilename) & vbCrLf
                End If
            End If
        Loop
        
        'Make sure we loaded at least one image from the original list
        If ((numSuccesses + numFailures) > 1) Or (numFailures > 0) Then
            Message "%1 of %2 images loaded successfully", numSuccesses, numSuccesses + numFailures
        Else
            Message vbNullString
        End If
        
        LoadMultipleImageFiles = CBool(numSuccesses > 0)
        
        SyncInterfaceToCurrentImage
        Processor.MarkProgramBusyState False, True, CBool(g_OpenImageCount > 1)
        
        'Even if returning TRUE, we still want to notify the user of any failed files
        If (numFailures > 0) Then
            PDMsgBox "Unfortunately, PhotoDemon was unable to load the following image(s):" & vbCrLf & vbCrLf & "%1" & vbCrLf & "Please verify that these image(s) exist, and that they use a supported image format (like JPEG or PNG).  Thanks!", vbExclamation + vbOKOnly + vbApplicationModal, "Some images were not loaded", brokenFiles
        End If
        
    Else
        LoadMultipleImageFiles = False
    End If

End Function

'This routine sets the message on the splash screen (used only when the program is first started)
Public Sub LoadMessage(ByVal sMsg As String)
    
    Static loadProgress As Long
        
    'In debug mode, mirror message output to PD's central Debugger
    #If DEBUGMODE = 1 Then
        pdDebug.LogAction sMsg, PDM_USER_MESSAGE
    #End If
    
    'Load messages are translatable, but we don't want to translate them if the translation object isn't ready yet
    If (Not g_Language Is Nothing) Then
        If g_Language.ReadyToTranslate Then
            If g_Language.TranslationActive Then sMsg = g_Language.TranslateMessage(sMsg)
        End If
    End If
    
    'Previously, the current load text would be displayed to the user at this point.  As of version 6.6, this step is skipped in favor
    ' of a more minimalist splash screen.
    ' TODO BY 6.8's RELEASE: revisit this function entirely, and consider removing it if applicable
    If FormSplash.Visible Then FormSplash.UpdateLoadProgress loadProgress
    
    loadProgress = loadProgress + 1
    
End Sub

'Loading all hotkeys (accelerators) requires a few different things.  Besides just populating the hotkey collection, we also paint all
' menu captions to match.
Public Sub LoadAccelerators()
    
    With FormMain.pdHotkeys
    
        .Enabled = True
    
        'File menu
        .AddAccelerator vbKeyN, vbCtrlMask, "New image", FormMain.MnuFile(0), True, False, True, UNDO_NOTHING
        .AddAccelerator vbKeyO, vbCtrlMask, "Open", FormMain.MnuFile(1), True, False, True, UNDO_NOTHING
        .AddAccelerator vbKeyF4, vbCtrlMask, "Close", FormMain.MnuFile(5), True, True, True, UNDO_NOTHING
        .AddAccelerator vbKeyF4, vbCtrlMask Or vbShiftMask, "Close all", FormMain.MnuFile(6), True, True, True, UNDO_NOTHING
        .AddAccelerator vbKeyS, vbCtrlMask, "Save", FormMain.MnuFile(8), True, True, True, UNDO_NOTHING
        .AddAccelerator vbKeyS, vbCtrlMask Or vbAltMask Or vbShiftMask, "Save copy", FormMain.MnuFile(9), True, False, True, UNDO_NOTHING
        .AddAccelerator vbKeyS, vbCtrlMask Or vbShiftMask, "Save as", FormMain.MnuFile(10), True, True, True, UNDO_NOTHING
        .AddAccelerator vbKeyF12, 0, "Revert", FormMain.MnuFile(11), True, True, False, UNDO_NOTHING
        .AddAccelerator vbKeyB, vbCtrlMask, "Batch wizard", FormMain.MnuBatch(0), True, False, True, UNDO_NOTHING
        .AddAccelerator vbKeyP, vbCtrlMask, "Print", FormMain.MnuFile(15), True, True, True, UNDO_NOTHING
        .AddAccelerator vbKeyQ, vbCtrlMask, "Exit program", FormMain.MnuFile(17), True, False, True, UNDO_NOTHING
        
            'File -> Import submenu
            .AddAccelerator vbKeyI, vbCtrlMask Or vbShiftMask Or vbAltMask, "Scan image", FormMain.MnuScanImage, True, False, True, UNDO_NOTHING
            .AddAccelerator vbKeyD, vbCtrlMask Or vbShiftMask, "Internet import", FormMain.MnuImportFromInternet, True, False, True, UNDO_NOTHING
            .AddAccelerator vbKeyI, vbCtrlMask Or vbAltMask, "Screen capture", FormMain.MnuScreenCapture, True, False, True, UNDO_NOTHING
        
            'Most-recently used files.  Note that we cannot automatically associate these with a menu, as these menus may not
            ' exist at run-time.  (They are dynamically created as necessary.)
            .AddAccelerator vbKey0, vbCtrlMask, "MRU_0"
            .AddAccelerator vbKey1, vbCtrlMask, "MRU_1"
            .AddAccelerator vbKey2, vbCtrlMask, "MRU_2"
            .AddAccelerator vbKey3, vbCtrlMask, "MRU_3"
            .AddAccelerator vbKey4, vbCtrlMask, "MRU_4"
            .AddAccelerator vbKey5, vbCtrlMask, "MRU_5"
            .AddAccelerator vbKey6, vbCtrlMask, "MRU_6"
            .AddAccelerator vbKey7, vbCtrlMask, "MRU_7"
            .AddAccelerator vbKey8, vbCtrlMask, "MRU_8"
            .AddAccelerator vbKey9, vbCtrlMask, "MRU_9"
            
        'Edit menu
        .AddAccelerator vbKeyZ, vbCtrlMask, "Undo", FormMain.MnuEdit(0), True, True, False, UNDO_NOTHING
        .AddAccelerator vbKeyY, vbCtrlMask, "Redo", FormMain.MnuEdit(1), True, True, False, UNDO_NOTHING
        
        .AddAccelerator vbKeyF, vbCtrlMask, "Repeat last action", FormMain.MnuEdit(4), True, True, False, UNDO_IMAGE
        
        .AddAccelerator vbKeyX, vbCtrlMask, "Cut", FormMain.MnuEdit(7), True, True, False, UNDO_IMAGE
        .AddAccelerator vbKeyX, vbCtrlMask Or vbShiftMask, "Cut from layer", FormMain.MnuEdit(8), True, True, False, UNDO_LAYER
        .AddAccelerator vbKeyC, vbCtrlMask, "Copy", FormMain.MnuEdit(9), True, True, False, UNDO_NOTHING
        .AddAccelerator vbKeyC, vbCtrlMask Or vbShiftMask, "Copy from layer", FormMain.MnuEdit(10), True, True, False, UNDO_NOTHING
        .AddAccelerator vbKeyV, vbCtrlMask, "Paste as new image", FormMain.MnuEdit(11), True, False, False, UNDO_NOTHING
        .AddAccelerator vbKeyV, vbCtrlMask Or vbShiftMask, "Paste as new layer", FormMain.MnuEdit(12), True, False, False, UNDO_IMAGE_VECTORSAFE
        
        'View menu
        .AddAccelerator vbKey0, 0, "FitOnScreen", FormMain.MnuFitOnScreen, False, True, False, UNDO_NOTHING
        .AddAccelerator vbKeyAdd, 0, "Zoom_In", FormMain.MnuZoomIn, False, True, False, UNDO_NOTHING
        .AddAccelerator VK_OEM_PLUS, 0, "Zoom_In", , False, True, False, UNDO_NOTHING
        .AddAccelerator vbKeySubtract, 0, "Zoom_Out", FormMain.MnuZoomOut, False, True, False, UNDO_NOTHING
        .AddAccelerator VK_OEM_MINUS, 0, "Zoom_Out", , False, True, False, UNDO_NOTHING
        .AddAccelerator vbKey5, 0, "Zoom_161", FormMain.MnuSpecificZoom(0), False, True, False, UNDO_NOTHING
        .AddAccelerator vbKey4, 0, "Zoom_81", FormMain.MnuSpecificZoom(1), False, True, False, UNDO_NOTHING
        .AddAccelerator vbKey3, 0, "Zoom_41", FormMain.MnuSpecificZoom(2), False, True, False, UNDO_NOTHING
        .AddAccelerator vbKey2, 0, "Zoom_21", FormMain.MnuSpecificZoom(3), False, True, False, UNDO_NOTHING
        .AddAccelerator vbKey1, 0, "Actual_Size", FormMain.MnuSpecificZoom(4), False, True, False, UNDO_NOTHING
        .AddAccelerator vbKey2, vbShiftMask, "Zoom_12", FormMain.MnuSpecificZoom(5), False, True, False, UNDO_NOTHING
        .AddAccelerator vbKey3, vbShiftMask, "Zoom_14", FormMain.MnuSpecificZoom(6), False, True, False, UNDO_NOTHING
        .AddAccelerator vbKey4, vbShiftMask, "Zoom_18", FormMain.MnuSpecificZoom(7), False, True, False, UNDO_NOTHING
        .AddAccelerator vbKey5, vbShiftMask, "Zoom_116", FormMain.MnuSpecificZoom(8), False, True, False, UNDO_NOTHING
        
        'Image menu
        .AddAccelerator vbKeyA, vbCtrlMask Or vbShiftMask, "Duplicate image", FormMain.MnuImage(0), True, True, False, UNDO_NOTHING
        .AddAccelerator vbKeyR, vbCtrlMask, "Resize image", FormMain.MnuImage(2), True, True, True, UNDO_IMAGE
        .AddAccelerator vbKeyR, vbCtrlMask Or vbAltMask, "Canvas size", FormMain.MnuImage(5), True, True, True, UNDO_IMAGEHEADER
        '.AddAccelerator vbKeyX, vbCtrlMask Or vbShiftMask, "Crop", FormMain.MnuImage(8), True, True, False, UNDO_IMAGE
        .AddAccelerator vbKeyX, vbCtrlMask Or vbAltMask, "Trim empty borders", FormMain.MnuImage(10), True, True, False, UNDO_IMAGEHEADER
        
            'Image -> Rotate submenu
            .AddAccelerator vbKeyR, 0, "Rotate image 90 clockwise", FormMain.MnuRotate(2), True, True, False, UNDO_IMAGE
            .AddAccelerator vbKeyL, 0, "Rotate image 90 counter-clockwise", FormMain.MnuRotate(3), True, True, False, UNDO_IMAGE
            .AddAccelerator vbKeyR, vbCtrlMask Or vbShiftMask Or vbAltMask, "Arbitrary image rotation", FormMain.MnuRotate(5), True, True, True, UNDO_NOTHING
        
        'Layer Menu
        '(none yet)
        
        
        'Select Menu
        .AddAccelerator vbKeyA, vbCtrlMask, "Select all", FormMain.MnuSelect(0), True, True, False, UNDO_SELECTION
        .AddAccelerator vbKeyD, vbCtrlMask, "Remove selection", FormMain.MnuSelect(1), False, True, False, UNDO_SELECTION
        .AddAccelerator vbKeyI, vbCtrlMask Or vbShiftMask, "Invert selection", FormMain.MnuSelect(2), True, True, False, UNDO_SELECTION
        'KeyCode VK_OEM_4 = {[  (next to the letter P), VK_OEM_6 = }]
        .AddAccelerator VK_OEM_6, vbCtrlMask Or vbAltMask, "Grow selection", FormMain.MnuSelect(4), True, True, True, UNDO_NOTHING
        .AddAccelerator VK_OEM_4, vbCtrlMask Or vbAltMask, "Shrink selection", FormMain.MnuSelect(5), True, True, True, UNDO_NOTHING
        .AddAccelerator vbKeyD, vbCtrlMask Or vbAltMask, "Feather selection", FormMain.MnuSelect(7), True, True, True, UNDO_NOTHING
        
        'Adjustments Menu
        
        'Adjustments top shortcut menu
        .AddAccelerator vbKeyU, vbCtrlMask Or vbShiftMask, "Black and white", FormMain.MnuAdjustments(3), True, True, True, UNDO_NOTHING
        .AddAccelerator vbKeyB, vbCtrlMask Or vbShiftMask, "Brightness and contrast", FormMain.MnuAdjustments(4), True, True, True, UNDO_NOTHING
        .AddAccelerator vbKeyC, vbCtrlMask Or vbAltMask, "Color balance", FormMain.MnuAdjustments(5), True, True, True, UNDO_NOTHING
        .AddAccelerator vbKeyM, vbCtrlMask, "Curves", FormMain.MnuAdjustments(6), True, True, True, UNDO_NOTHING
        .AddAccelerator vbKeyL, vbCtrlMask, "Levels", FormMain.MnuAdjustments(7), True, True, True, UNDO_NOTHING
        .AddAccelerator vbKeyH, vbCtrlMask Or vbShiftMask, "Shadow and highlight", FormMain.MnuAdjustments(8), True, True, True, UNDO_NOTHING
        .AddAccelerator vbKeyAdd, vbCtrlMask Or vbAltMask, "Vibrance", FormMain.MnuAdjustments(9), True, True, True, UNDO_NOTHING
        .AddAccelerator VK_OEM_PLUS, vbCtrlMask Or vbAltMask, "Vibrance", , True, True, True, UNDO_NOTHING
        .AddAccelerator vbKeyW, vbCtrlMask, "White balance", FormMain.MnuAdjustments(10), True, True, True, UNDO_NOTHING
        
            'Color adjustments
            .AddAccelerator vbKeyH, vbCtrlMask, "Hue and saturation", FormMain.MnuColor(3), True, True, True, UNDO_NOTHING
            .AddAccelerator vbKeyT, vbCtrlMask, "Temperature", FormMain.MnuColor(4), True, True, True, UNDO_NOTHING
            
            'Lighting adjustments
            .AddAccelerator vbKeyG, vbCtrlMask, "Gamma", FormMain.MnuLighting(2), True, True, True, UNDO_NOTHING
            
            'Adjustments -> Invert submenu
            .AddAccelerator vbKeyI, vbCtrlMask, "Invert RGB", FormMain.MnuInvert(2), True, True, False, UNDO_LAYER
            
            'Adjustments -> Monochrome submenu
            .AddAccelerator vbKeyB, vbCtrlMask Or vbAltMask Or vbShiftMask, "Color to monochrome", FormMain.MnuMonochrome(0), True, True, True, UNDO_NOTHING
            
            'Adjustments -> Photography submenu
            .AddAccelerator vbKeyE, vbCtrlMask Or vbAltMask, "Exposure", FormMain.MnuAdjustmentsPhoto(0), True, True, True, UNDO_NOTHING
            .AddAccelerator vbKeyP, vbCtrlMask Or vbAltMask, "Photo filter", FormMain.MnuAdjustmentsPhoto(2), True, True, True, UNDO_NOTHING
            
        
        'Effects Menu
        '.AddAccelerator vbKeyZ, vbCtrlMask Or vbAltMask Or vbShiftMask, "Add RGB noise", FormMain.MnuNoise(1), True, True, True, False
        '.AddAccelerator vbKeyG, vbCtrlMask Or vbAltMask Or vbShiftMask, "Gaussian blur", FormMain.MnuBlurFilter(1), True, True, True, False
        '.AddAccelerator vbKeyY, vbCtrlMask Or vbAltMask Or vbShiftMask, "Correct lens distortion", FormMain.MnuDistortEffects(1), True, True, True, False
        '.AddAccelerator vbKeyU, vbCtrlMask Or vbAltMask Or vbShiftMask, "Unsharp mask", FormMain.MnuSharpen(1), True, True, True, False
        
        'Tools menu
        'KeyCode 190 = >.  (two keys to the right of the M letter key)
        .AddAccelerator 190, vbCtrlMask Or vbAltMask, "Play macro", FormMain.MnuTool(6), True, True, True, UNDO_NOTHING
        
        .AddAccelerator vbKeyReturn, vbAltMask, "Preferences", FormMain.MnuTool(9), False, False, True, UNDO_NOTHING
        .AddAccelerator vbKeyM, vbCtrlMask Or vbAltMask, "Plugin manager", FormMain.MnuTool(10), False, False, True, UNDO_NOTHING
        
        
        'Window menu
        .AddAccelerator vbKeyPageDown, 0, "Next_Image", FormMain.MnuWindow(5), False, True, False, UNDO_NOTHING
        .AddAccelerator vbKeyPageUp, 0, "Prev_Image", FormMain.MnuWindow(6), False, True, False, UNDO_NOTHING
        
        'Activate hotkey detection
        .ActivateHook
        
    End With
    
    'Before exiting, paint all shortcut captions to their respective menus
    DrawAccelerators
    
End Sub

'After all menu shortcuts (accelerators) are loaded above, the custom shortcuts need to be painted to their corresponding menus
Public Sub DrawAccelerators()

    Dim i As Long
    
    With FormMain.pdHotkeys
        For i = 0 To .Count - 1
            If .HasMenu(i) Then
                .MenuReference(i).Caption = .MenuReference(i).Caption & vbTab & .StringRepresentation(i)
            End If
        Next i
    End With

    'A few menu shortcuts must be drawn manually.
    
    'Because the Import -> From Clipboard menu shares the same shortcut as Edit -> Paste as new image, we must
    ' manually add its shortcut (as only the Edit -> Paste will be handled automatically).
    FormMain.MnuImportClipboard.Caption = FormMain.MnuImportClipboard.Caption & vbTab & g_Language.TranslateMessage("Ctrl") & "+V"
    
    'Similarly for the Layer -> New -> From Clipboard menu
    FormMain.MnuLayerNew(3).Caption = FormMain.MnuLayerNew(3).Caption & vbTab & g_Language.TranslateMessage("Ctrl") & "+" & g_Language.TranslateMessage("Shift") & "+V"
    
    'NOTE: Drawing of MRU shortcuts is handled in the MRU module
    
End Sub

'Make a copy of the current image.  Thanks to PSC user "Achmad Junus" for this suggestion.
Public Sub DuplicateCurrentImage()
    
    Message "Duplicating current image..."
    
    'Ask the currently active image to write itself out to file
    Dim tmpDuplicationFile As String
    tmpDuplicationFile = g_UserPreferences.GetTempPath & "PDDuplicate.pdi"
    SavePhotoDemonImage pdImages(g_CurrentImage), tmpDuplicationFile, True, PD_CE_Lz4, PD_CE_Lz4, False
    
    'We can now use the standard image load routine to import the temporary file
    Dim sTitle As String
    sTitle = pdImages(g_CurrentImage).imgStorage.GetEntry_String("OriginalFileName", vbNullString)
    If Len(sTitle) = 0 Then sTitle = g_Language.TranslateMessage("[untitled image]")
    sTitle = sTitle & " - " & g_Language.TranslateMessage("Copy")
    
    LoadFileAsNewImage tmpDuplicationFile, sTitle, False
                    
    'Be polite and remove the temporary file
    Dim cFile As pdFSO
    Set cFile = New pdFSO
    If cFile.FileExist(tmpDuplicationFile) Then cFile.KillFile tmpDuplicationFile
    
    Message "Image duplication complete."
        
End Sub
