VERSION 5.00
Begin VB.Form FormDiffuse 
   BackColor       =   &H80000005&
   BorderStyle     =   4  'Fixed ToolWindow
   Caption         =   " Custom Diffuse"
   ClientHeight    =   6540
   ClientLeft      =   45
   ClientTop       =   285
   ClientWidth     =   12210
   BeginProperty Font 
      Name            =   "Tahoma"
      Size            =   8.25
      Charset         =   0
      Weight          =   400
      Underline       =   0   'False
      Italic          =   0   'False
      Strikethrough   =   0   'False
   EndProperty
   LinkTopic       =   "Form1"
   MaxButton       =   0   'False
   MinButton       =   0   'False
   ScaleHeight     =   436
   ScaleMode       =   3  'Pixel
   ScaleWidth      =   814
   ShowInTaskbar   =   0   'False
   Begin PhotoDemon.pdCommandBar cmdBar 
      Align           =   2  'Align Bottom
      Height          =   750
      Left            =   0
      TabIndex        =   0
      Top             =   5790
      Width           =   12210
      _ExtentX        =   21537
      _ExtentY        =   1323
   End
   Begin PhotoDemon.pdSlider sltX 
      Height          =   705
      Left            =   6000
      TabIndex        =   3
      Top             =   1680
      Width           =   6015
      _ExtentX        =   10610
      _ExtentY        =   1270
      Caption         =   "horizontal strength"
      Value           =   1
      DefaultValue    =   1
   End
   Begin PhotoDemon.pdCheckBox chkWrap 
      Height          =   330
      Left            =   6120
      TabIndex        =   2
      Top             =   3600
      Width           =   5550
      _ExtentX        =   9790
      _ExtentY        =   582
      Caption         =   "wrap edge values"
   End
   Begin PhotoDemon.pdFxPreviewCtl pdFxPreview 
      Height          =   5625
      Left            =   120
      TabIndex        =   1
      Top             =   120
      Width           =   5625
      _ExtentX        =   9922
      _ExtentY        =   9922
   End
   Begin PhotoDemon.pdSlider sltY 
      Height          =   705
      Left            =   6000
      TabIndex        =   4
      Top             =   2640
      Width           =   6015
      _ExtentX        =   10610
      _ExtentY        =   1270
      Caption         =   "vertical strength"
      Value           =   1
      DefaultValue    =   1
   End
End
Attribute VB_Name = "FormDiffuse"
Attribute VB_GlobalNameSpace = False
Attribute VB_Creatable = False
Attribute VB_PredeclaredId = True
Attribute VB_Exposed = False
'***************************************************************************
'Diffuse Filter Handler
'Copyright 2001-2017 by Tanner Helland
'Created: 8/14/01
'Last updated: 22/August/13
'Last update: add command bar user control
'
'Module for handling "diffuse"-style filters (also called "displace", e.g. in GIMP).
'
'All source code in this file is licensed under a modified BSD license.  This means you may use the code in your own
' projects IF you provide attribution.  For more information, please visit http://photodemon.org/about/license/
'
'***************************************************************************

Option Explicit

'When previewing, we need to modify the strength to be representative of the final filter.  This means dividing by the
' original image width in order to establish the right ratio.
Private iWidth As Long, iHeight As Long

Private Sub ChkWrap_Click()
    UpdatePreview
End Sub

'OK button
Private Sub cmdBar_OKClick()
    Process "Diffuse", , BuildParams(sltX.Value, sltY.Value, CBool(chkWrap.Value)), UNDO_LAYER
End Sub

Private Sub cmdBar_RequestPreviewUpdate()
    UpdatePreview
End Sub

Private Sub Form_Load()

    'Disable previews until everything is loaded
    cmdBar.MarkPreviewStatus False
    
    'Note the current image's width and height, which will be needed to adjust the preview effect
    If pdImages(g_CurrentImage).IsSelectionActive Then
        Dim selBounds As RECTF
        selBounds = pdImages(g_CurrentImage).mainSelection.GetBoundaryRect()
        iWidth = selBounds.Width
        iHeight = selBounds.Height
    Else
        iWidth = pdImages(g_CurrentImage).Width
        iHeight = pdImages(g_CurrentImage).Height
    End If
    
    'Adjust the scroll bar dimensions to match the current image's width and height
    sltX.Max = iWidth - 1
    sltY.Max = iHeight - 1
    sltX.Value = Int(sltX.Max \ 2)
    sltY.Value = Int(sltY.Max \ 2)
    
    'Apply translations and visual themes
    ApplyThemeAndTranslations Me
    cmdBar.MarkPreviewStatus True
    UpdatePreview
    
End Sub

Private Sub Form_Unload(Cancel As Integer)
    ReleaseFormTheming Me
End Sub

'Custom diffuse effect
' Inputs: diameter in x direction, diameter in y direction, whether or not to wrap edge pixels, and optional preview settings
Public Sub DiffuseCustom(ByVal xDiffuse As Long, ByVal yDiffuse As Long, ByVal wrapPixels As Boolean, Optional ByVal toPreview As Boolean = False, Optional ByRef dstPic As pdFxPreviewCtl)

    If Not toPreview Then Message "Simulating large image explosion..."
    
    'Create a local array and point it at the pixel data of the current image
    Dim dstImageData() As Byte
    Dim dstSA As SAFEARRAY2D
    PrepImageData dstSA, toPreview, dstPic
    CopyMemory ByVal VarPtrArray(dstImageData()), VarPtr(dstSA), 4
    
    'Create a second local array.  This will contain the a copy of the current image, and we will use it as our source reference
    ' (This is necessary to prevent diffused pixels from spreading across the image as we go.)
    Dim srcImageData() As Byte
    Dim srcSA As SAFEARRAY2D
    
    Dim srcDIB As pdDIB
    Set srcDIB = New pdDIB
    srcDIB.CreateFromExistingDIB workingDIB
    
    PrepSafeArray srcSA, srcDIB
    CopyMemory ByVal VarPtrArray(srcImageData()), VarPtr(srcSA), 4
        
    'Local loop variables can be more efficiently cached by VB's compiler, so we transfer all relevant loop data here
    Dim x As Long, y As Long, initX As Long, initY As Long, finalX As Long, finalY As Long
    initX = curDIBValues.Left
    initY = curDIBValues.Top
    finalX = curDIBValues.Right
    finalY = curDIBValues.Bottom
    
    'If this is a preview, we need to adjust the xDiffuse and yDiffuse values to match the size of the preview box
    If toPreview Then
        xDiffuse = (xDiffuse / iWidth) * curDIBValues.Width
        yDiffuse = (yDiffuse / iHeight) * curDIBValues.Height
    End If
    
    'These values will help us access locations in the array more quickly.
    ' (qvDepth is required because the image array may be 24 or 32 bits per pixel, and we want to handle both cases.)
    Dim quickVal As Long, quickValDiffuseX As Long, quickValDiffuseY As Long, qvDepth As Long
    qvDepth = curDIBValues.BytesPerPixel
    
    Dim maxX As Long
    maxX = finalX * qvDepth
        
    'To keep processing quick, only update the progress bar when absolutely necessary.  This function calculates that value
    ' based on the size of the area to be processed.
    Dim progBarCheck As Long
    progBarCheck = FindBestProgBarValue()

    'Seed the random number generator with a pseudo-random value (the number of milliseconds elapsed since midnight)
    Randomize Timer
    
    'hDX and hDY are the half-values (or radius) of the diffuse area.  Pre-calculating them is faster than recalculating
    ' them every time we need to access a radius value.
    Dim hDX As Double, hDY As Double
    hDX = xDiffuse / 2
    hDY = yDiffuse / 2
    
    'Finally, these two variables will be used to store the position of diffused pixels
    Dim DiffuseX As Long, DiffuseY As Long
    
    'Loop through each pixel in the image, diffusing as we go
    For x = initX To finalX
        quickVal = x * qvDepth
    For y = initY To finalY
        
        DiffuseX = Rnd * xDiffuse - hDX
        DiffuseY = Rnd * yDiffuse - hDY
        
        quickValDiffuseX = (DiffuseX * qvDepth) + quickVal
        quickValDiffuseY = DiffuseY + y
            
        'Make sure the diffused pixel is within image boundaries, and if not adjust it according to the user's
        ' "wrapPixels" setting.
        If wrapPixels Then
            If quickValDiffuseX < 0 Then quickValDiffuseX = quickValDiffuseX + maxX
            If quickValDiffuseY < 0 Then quickValDiffuseY = quickValDiffuseY + finalY
            
            If quickValDiffuseX > maxX Then quickValDiffuseX = quickValDiffuseX - maxX
            If quickValDiffuseY > finalY Then quickValDiffuseY = quickValDiffuseY - finalY
        Else
            If quickValDiffuseX < 0 Then quickValDiffuseX = 0
            If quickValDiffuseY < 0 Then quickValDiffuseY = 0
            
            If quickValDiffuseX > maxX Then quickValDiffuseX = maxX
            If quickValDiffuseY > finalY Then quickValDiffuseY = finalY
        End If
            
        dstImageData(quickVal + 2, y) = srcImageData(quickValDiffuseX + 2, quickValDiffuseY)
        dstImageData(quickVal + 1, y) = srcImageData(quickValDiffuseX + 1, quickValDiffuseY)
        dstImageData(quickVal, y) = srcImageData(quickValDiffuseX, quickValDiffuseY)
        
        'Handle alpha as well, if present
        If qvDepth = 4 Then dstImageData(quickVal + 3, y) = srcImageData(quickValDiffuseX + 3, quickValDiffuseY)

    Next y
        If toPreview = False Then
            If (x And progBarCheck) = 0 Then
                If UserPressedESC() Then Exit For
                SetProgBarVal x
            End If
        End If
    Next x
    
    'With our work complete, point both ImageData() arrays away from their DIBs and deallocate them
    CopyMemory ByVal VarPtrArray(srcImageData), 0&, 4
    Erase srcImageData
    
    CopyMemory ByVal VarPtrArray(dstImageData), 0&, 4
    Erase dstImageData
    
    'Pass control to finalizeImageData, which will handle the rest of the rendering
    FinalizeImageData toPreview, dstPic
     
End Sub

Private Sub sltX_Change()
    UpdatePreview
End Sub

Private Sub UpdatePreview()
    If cmdBar.PreviewsAllowed Then DiffuseCustom sltX.Value, sltY.Value, CBool(chkWrap.Value), True, pdFxPreview
End Sub

Private Sub sltY_Change()
    UpdatePreview
End Sub

'If the user changes the position and/or zoom of the preview viewport, the entire preview must be redrawn.
Private Sub pdFxPreview_ViewportChanged()
    UpdatePreview
End Sub

Private Function GetLocalParamString() As String
    
    Dim cParams As pdParamXML
    Set cParams = New pdParamXML
    
    With cParams
    
    End With
    
    GetLocalParamString = cParams.GetParamString()
    
End Function
