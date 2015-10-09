VERSION 5.00
Begin VB.UserControl pdScrollBar 
   Appearance      =   0  'Flat
   BackColor       =   &H80000005&
   ClientHeight    =   600
   ClientLeft      =   0
   ClientTop       =   0
   ClientWidth     =   4800
   BeginProperty Font 
      Name            =   "Tahoma"
      Size            =   8.25
      Charset         =   0
      Weight          =   400
      Underline       =   0   'False
      Italic          =   0   'False
      Strikethrough   =   0   'False
   EndProperty
   ScaleHeight     =   40
   ScaleMode       =   3  'Pixel
   ScaleWidth      =   320
   Begin VB.Timer tmrUpButton 
      Enabled         =   0   'False
      Left            =   0
      Top             =   120
   End
   Begin VB.Timer tmrDownButton 
      Enabled         =   0   'False
      Left            =   0
      Top             =   0
   End
End
Attribute VB_Name = "pdScrollBar"
Attribute VB_GlobalNameSpace = False
Attribute VB_Creatable = True
Attribute VB_PredeclaredId = False
Attribute VB_Exposed = False
'***************************************************************************
'PhotoDemon Scrollbar control
'Copyright 2015-2015 by Tanner Helland
'Created: 07/October/15
'Last updated: 07/October/15
'Last update: initial build
'
'In a surprise to precisely no one, PhotoDemon has some unique needs when it comes to user controls - needs that
' the intrinsic VB controls can't handle.  These range from the obnoxious (lack of an "autosize" property for
' anything but labels) to the critical (no Unicode support).
'
'As such, I've created many of my own UCs for the program.  All are owner-drawn, with the goal of maintaining
' visual fidelity across the program, while also enabling key features like Unicode support.
'
'A few notes on this scroll bar control, specifically:
'
' 1) Unlike traditional scroll bars, only a single "Scroll" event is raised (vs Scroll and Change events).  This event
'    includes a parameter that lets you know what kind of scroll is occurring.
' 2) High DPI settings are handled automatically.
' 3) A hand cursor is automatically applied.
' 4) Coloration is automatically handled by PD's internal theming engine.
' 5) This control represents both horizontal and vertical orientations.  Set the corresponding property to match,
'     but be forwarned that this does *not* automatically change the control's size to match!  This is by design.
'
'All source code in this file is licensed under a modified BSD license.  This means you may use the code in your own
' projects IF you provide attribution.  For more information, please visit http://photodemon.org/about/license/
'
'***************************************************************************

Option Explicit

'This control really only needs one event raised - Scroll.  The "eventIsCritical" parameter can optionally be tested;
' it returns FALSE for events that would be considered a "scroll" by VB (e.g. click-dragging), which you could theoretically
' ignore if you were worried about performance.  If eventIsCritical is TRUE, however, you must respond to the event.
Public Event Scroll(ByVal eventIsCritical As Boolean)

'API technique for drawing a focus rectangle; used only for designer mode (see the Paint method for details)
Private Declare Function DrawFocusRect Lib "user32" (ByVal hDC As Long, ByRef lpRect As RECT) As Long

'Mouse and keyboard input handlers
Private WithEvents cMouseEvents As pdInputMouse
Attribute cMouseEvents.VB_VarHelpID = -1
Private WithEvents cKeyEvents As pdInputKeyboard
Attribute cKeyEvents.VB_VarHelpID = -1

'Flicker-free window painter
Private WithEvents cPainter As pdWindowPainter
Attribute cPainter.VB_VarHelpID = -1

'Reliable focus detection requires a specialized subclasser
Private WithEvents cFocusDetector As pdFocusDetector
Attribute cFocusDetector.VB_VarHelpID = -1
Public Event GotFocusAPI()
Public Event LostFocusAPI()

'Persistent back buffer, which we manage internally.  This allows for color management (yes, even on UI elements!)
Private m_BackBuffer As pdDIB

'If the mouse is currently INSIDE the control, this will be set to TRUE
Private m_MouseInsideUC As Boolean

'When the control receives focus via keyboard (e.g. NOT by mouse events), we draw a focus rect to help orient the user.
Private m_FocusRectActive As Boolean

'Current back color
Private m_BackColor As OLE_COLOR

'Additional helper for rendering themed and multiline tooltips
Private toolTipManager As pdToolTip

'If the control is currently visible, this will be set to TRUE.  This can be used to suppress redraw requests for hidden controls.
Private m_ControlIsVisible As Boolean

'The scrollbar's orientation is cached at creation time, in case subsequent functions need it
Private m_OrientationHorizontal As Boolean

'Current scroll bar values, range, etc
Private m_Value As Double, m_Min As Double, m_Max As Double, m_SmallChange As Double, m_LargeChange As Double

'The number of significant digits for this control.  0 means integer values.
Private m_significantDigits As Long

'To simplify mouse_down handling, resize events fill three rects: one for the "up" or "left" scroll button, one for
' the "down" or "right" scroll button, and a third one, for the track rect between the buttons.
Private upLeftRect As RECTL, downRightRect As RECTL, trackRect As RECTL

'Max/min property changes fill a third rect - the "thumb" rect - which is the bar in the middle of the scroll bar.
' Note that the thumb rect is a RECTF, because it supports subpixel positioning.
Private thumbRect As RECTF

'To simplify thumb calculations, we calculate its size only when necessary, and cache it.  Note that the size
' is directionless (e.g. it represents the height for a vertical Thumb, and the width for a horizontal one).
Private m_ThumbSize As Single

'Mouse state for the up/down buttons and thumb.  These are important for not just rendering, but in the case of the buttons,
' for controlling a timer that enables "press and hold" behavior.
Private m_MouseDownThumb As Boolean, m_MouseOverThumb As Boolean
Private m_MouseDownUpButton As Boolean, m_MouseDownDownButton As Boolean
Private m_MouseOverUpButton As Boolean, m_MouseOverDownButton As Boolean

'To simplify our lives, we use the API for some rect calculations.
Private Declare Function IntersectRect Lib "user32" (ByRef lpDestRect As RECTL, ByRef lpSrc1Rect As RECTL, ByRef lpSrc2Rect As RECTL) As Long

'The Enabled property is a bit unique; see http://msdn.microsoft.com/en-us/library/aa261357%28v=vs.60%29.aspx
Public Property Get Enabled() As Boolean
Attribute Enabled.VB_UserMemId = -514
    Enabled = UserControl.Enabled
End Property

Public Property Let Enabled(ByVal newValue As Boolean)
    
    UserControl.Enabled = newValue
    PropertyChanged "Enabled"
    
    'Redraw the control
    redrawBackBuffer
    
End Property

'hWnds aren't exposed by default
Public Property Get hWnd() As Long
    hWnd = UserControl.hWnd
End Property

'Container hWnd must be exposed for external tooltip handling
Public Property Get containerHwnd() As Long
    containerHwnd = UserControl.containerHwnd
End Property

Public Property Get OrientationHorizontal() As Boolean
    OrientationHorizontal = m_OrientationHorizontal
End Property

Public Property Let OrientationHorizontal(ByVal newState As Boolean)
    If m_OrientationHorizontal <> newState Then
        m_OrientationHorizontal = newState
        updateControlLayout
        PropertyChanged "OrientationHorizontal"
    End If
End Property

Public Property Get Value() As Double
    Value = m_Value
End Property

Public Property Let Value(ByVal newValue As Double)
        
    'Don't make any changes unless the new value deviates from the existing one
    If (newValue <> m_Value) Then
        
        m_Value = newValue
                
        'While running, perform bounds-checking.  (It's less important in the designer, as the assumption is that the
        ' developer will momentarily bring everything into order.)
        If g_IsProgramRunning Then
            
            'To prevent RTEs, perform an additional bounds check.  Clamp the value if it lies outside control boundaries.
            If m_Value < m_Min Then m_Value = m_Min
            If m_Value > m_Max Then m_Value = m_Max
            
        End If
        
        'Recalculate the current thumb position, then redraw the button
        determineThumbSize
        redrawBackBuffer True
        
        'Mark the value property as being changed, and raise the corresponding event.
        PropertyChanged "Value"
        RaiseEvent Scroll(True)
        
    End If
                
End Property

'Note: the control's minimum value is settable at run-time
Public Property Get Min() As Double
    Min = m_Min
End Property

Public Property Let Min(ByVal newValue As Double)
        
    m_Min = newValue
    
    'If the current control .Value is less than the new minimum, change it to match
    If m_Value < m_Min Then
        m_Value = m_Min
        RaiseEvent Scroll(True)
    End If
    
    'Recalculate thumb size and position, then redraw the button to match
    determineThumbSize
    If g_IsProgramRunning Then cPainter.requestRepaint
    
    PropertyChanged "Min"
    
End Property

'Note: the control's maximum value is settable at run-time
Public Property Get Max() As Double
    Max = m_Max
End Property

Public Property Let Max(ByVal newValue As Double)
        
    m_Max = newValue
    
    'If the current control .Value is greater than the new max, change it to match
    If m_Value > m_Max Then
        m_Value = m_Max
        RaiseEvent Scroll(True)
    End If
    
    'Recalculate thumb size and position
    determineThumbSize
    If g_IsProgramRunning Then cPainter.requestRepaint
    
    PropertyChanged "Max"
    
End Property

'Significant digits determines whether the control allows float values or int values (and with how much precision)
Public Property Get SigDigits() As Long
    SigDigits = m_significantDigits
End Property

Public Property Let SigDigits(ByVal newValue As Long)
    m_significantDigits = newValue
    PropertyChanged "SigDigits"
End Property

Public Property Get SmallChange() As Long
    SmallChange = m_SmallChange
End Property

Public Property Let SmallChange(ByVal newValue As Long)
    m_SmallChange = newValue
    PropertyChanged "SmallChange"
End Property

Public Property Get LargeChange() As Long
    LargeChange = m_LargeChange
End Property

Public Property Let LargeChange(ByVal newValue As Long)
    m_LargeChange = newValue
    PropertyChanged "LargeChange"
End Property

'When the control receives focus, if the focus isn't received via mouse click, display a focus rect
Private Sub cFocusDetector_GotFocusReliable()
    
    'If the mouse is *not* over the user control, assume focus was set via keyboard
    If Not m_MouseInsideUC Then
        m_FocusRectActive = True
        redrawBackBuffer
    End If
    
    RaiseEvent GotFocusAPI
    
End Sub

'When the control loses focus, erase any focus rects it may have active
Private Sub cFocusDetector_LostFocusReliable()
    makeLostFocusUIChanges
    RaiseEvent LostFocusAPI
End Sub

Private Sub makeLostFocusUIChanges()
    
    'If a focus rect has been drawn, remove it now
    If m_FocusRectActive Or m_MouseInsideUC Then
        m_FocusRectActive = False
        m_MouseInsideUC = False
        redrawBackBuffer
    End If
    
End Sub

'A few key events are also handled
Private Sub cKeyEvents_KeyUpCustom(ByVal Shift As ShiftConstants, ByVal vkCode As Long, markEventHandled As Boolean)

    'When space is released, redraw the button to match
'    If (vkCode = VK_SPACE) Or (vkCode = VK_RETURN) Then
'
'        If m_FocusRectActive And Me.Enabled Then
'            m_TitleState = Not m_TitleState
'            redrawBackBuffer
'            RaiseEvent Click(m_TitleState)
'        End If
'
'    End If

End Sub

'Only left clicks raise Click() events
Private Sub cMouseEvents_MouseDownCustom(ByVal Button As PDMouseButtonConstants, ByVal Shift As ShiftConstants, ByVal x As Long, ByVal y As Long)
    
    If Me.Enabled And ((Button And pdLeftButton) <> 0) Then
    
        'Ensure that a focus event has been raised, if it wasn't already
        If Not cFocusDetector.HasFocus Then cFocusDetector.setFocusManually
        
        'Right button isn't currently handled, but it should probably raise a context menu...?
        If (Button = pdLeftButton) And Me.Enabled Then
            
            'Determine mouse button state for the up and down button areas
            If Math_Functions.isPointInRectL(x, y, upLeftRect) Then
                m_MouseDownUpButton = True
                
                'Adjust the value immediately
                moveValueDown
                
                'Start the repeat timer as well
                tmrUpButton.Interval = Interface.GetKeyboardDelay() * 1000
                tmrUpButton.Enabled = True
                
            Else
                m_MouseDownUpButton = False
            End If
            
            If Math_Functions.isPointInRectL(x, y, downRightRect) Then
                m_MouseDownDownButton = True
                moveValueUp
                tmrDownButton.Interval = Interface.GetKeyboardDelay() * 1000
                tmrDownButton.Enabled = True
            Else
                m_MouseDownDownButton = False
            End If
            
            'Determine button state for the thumb
            If Math_Functions.isPointInRectF(x, y, thumbRect) Then
                m_MouseDownThumb = True
            Else
                m_MouseDownThumb = False
            End If
            
            'Request a redraw
            redrawBackBuffer
            
        End If
        
    End If
    
End Sub

Private Sub cMouseEvents_MouseEnter(ByVal Button As PDMouseButtonConstants, ByVal Shift As ShiftConstants, ByVal x As Long, ByVal y As Long)
    m_MouseInsideUC = True
    cMouseEvents.setSystemCursor IDC_HAND
'    redrawBackBuffer
End Sub

'When the mouse leaves the UC, we must repaint the button (as it's no longer hovered)
Private Sub cMouseEvents_MouseLeave(ByVal Button As PDMouseButtonConstants, ByVal Shift As ShiftConstants, ByVal x As Long, ByVal y As Long)
    
    If m_MouseInsideUC Then
        
        m_MouseOverUpButton = False
        m_MouseOverDownButton = False
        m_MouseOverThumb = False
        
        m_MouseInsideUC = False
        redrawBackBuffer
        
    End If
    
    'Reset the cursor
    cMouseEvents.setSystemCursor IDC_ARROW
    
End Sub

'When the mouse enters the button, we must initiate a repaint (to reflect its hovered state)
Private Sub cMouseEvents_MouseMoveCustom(ByVal Button As PDMouseButtonConstants, ByVal Shift As ShiftConstants, ByVal x As Long, ByVal y As Long)
    
    'Reset mouse capture behavior; this greatly simplifies parts of the drawing function
    If Not m_MouseInsideUC Then m_MouseInsideUC = True
    
    'Determine mouse hover state for the up and down button areas
    If Math_Functions.isPointInRectL(x, y, upLeftRect) Then
        m_MouseOverUpButton = True
    Else
        m_MouseOverUpButton = False
    End If
    
    If Math_Functions.isPointInRectL(x, y, downRightRect) Then
        m_MouseOverDownButton = True
    Else
        m_MouseOverDownButton = False
    End If
        
    If Math_Functions.isPointInRectF(x, y, thumbRect) Then
        m_MouseOverThumb = True
    Else
        m_MouseOverThumb = False
    End If
        
    'Repaint the control
    ' TODO: add conditional checks, as some moves may not require a redraw
    redrawBackBuffer
    
End Sub

Private Sub cMouseEvents_MouseUpCustom(ByVal Button As PDMouseButtonConstants, ByVal Shift As ShiftConstants, ByVal x As Long, ByVal y As Long, ByVal ClickEventAlsoFiring As Boolean)
    
    If Button = pdLeftButton Then
        
        m_MouseDownUpButton = False
        m_MouseDownDownButton = False
        tmrUpButton.Enabled = False
        tmrDownButton.Enabled = False
        
        'When the mouse is released, raise a final "Scroll" event with the crucial parameter set to TRUE, which lets the
        ' caller know that they can perform any long-running actions now.
        RaiseEvent Scroll(True)
        
        'Request a redraw
        redrawBackBuffer
        
    End If
    
End Sub

'The pdWindowPaint class raises this event when the control needs to be redrawn.  The passed coordinates contain the
' rect returned by GetUpdateRect (but with right/bottom measurements pre-converted to width/height).
Private Sub cPainter_PaintWindow(ByVal winLeft As Long, ByVal winTop As Long, ByVal winWidth As Long, ByVal winHeight As Long)

    'Flip the relevant chunk of the buffer to the screen
    If Not (m_BackBuffer Is Nothing) Then
        BitBlt UserControl.hDC, winLeft, winTop, winWidth, winHeight, m_BackBuffer.getDIBDC, winLeft, winTop, vbSrcCopy
    End If
    
End Sub

Private Sub UserControl_Hide()
    m_ControlIsVisible = False
End Sub

'INITIALIZE control
Private Sub UserControl_Initialize()
    
    'When not in design mode, initialize trackers for input events
    If g_IsProgramRunning Then
    
        Set cMouseEvents = New pdInputMouse
        cMouseEvents.addInputTracker Me.hWnd, True, True, , True
        cMouseEvents.setSystemCursor IDC_HAND
        
        Set cKeyEvents = New pdInputKeyboard
        cKeyEvents.createKeyboardTracker "pdScrollBar", Me.hWnd, VK_UP, VK_DOWN, VK_RIGHT, VK_LEFT
        
        'Also start a flicker-free window painter
        Set cPainter = New pdWindowPainter
        cPainter.startPainter Me.hWnd
        
        'Also start a focus detector
        Set cFocusDetector = New pdFocusDetector
        cFocusDetector.startFocusTracking Me.hWnd
        
        'Create a tooltip engine
        Set toolTipManager = New pdToolTip
        
    'In design mode, initialize a base theming class, so our paint function doesn't fail
    Else
        If g_Themer Is Nothing Then Set g_Themer = New pdVisualThemes
    End If
    
    m_MouseInsideUC = False
    m_FocusRectActive = False
    
    'Update the control size parameters at least once
    updateControlLayout
                
End Sub

'Set default properties
Private Sub UserControl_InitProperties()
    BackColor = vbWhite
    Min = 0
    Max = 10
    Value = 0
    SmallChange = 1
    LargeChange = 1
    SigDigits = 0
    OrientationHorizontal = False
End Sub

Private Sub UserControl_LostFocus()
    makeLostFocusUIChanges
End Sub

'At run-time, painting is handled by PD's pdWindowPainter class.  In the IDE, however, we must rely on VB's internal paint event.
Private Sub UserControl_Paint()
    
    'Provide minimal painting within the designer
    If Not g_IsProgramRunning Then redrawBackBuffer
    
End Sub

Private Sub UserControl_ReadProperties(PropBag As PropertyBag)

    With PropBag
        BackColor = .ReadProperty("BackColor", vbWhite)
        Min = .ReadProperty("Min", 0)
        Max = .ReadProperty("Max", 10)
        Value = .ReadProperty("Value", 0)
        SmallChange = .ReadProperty("SmallChange", 1)
        LargeChange = .ReadProperty("LargeChange", 1)
        SigDigits = .ReadProperty("SignificantDigits", 0)
        OrientationHorizontal = .ReadProperty("OrientationHorizontal", False)
    End With

End Sub

'The control dynamically resizes each button to match the dimensions of their relative captions.
Private Sub UserControl_Resize()
    updateControlLayout
End Sub

'Timers control repeat value changes when the mouse is held down on an up/down button
Private Sub tmrDownButton_Timer()

    'If this is the first time the button is firing, we want to reset the button's interval to the repeat rate instead
    ' of the delay rate.
    If tmrDownButton.Interval = Interface.GetKeyboardDelay * 1000 Then
        tmrDownButton.Interval = Interface.GetKeyboardRepeatRate * 1000
    End If
    
    'It's a little counter-intuitive, but the DOWN button actually moves the control value UP
    moveValueUp

End Sub

Private Sub tmrUpButton_Timer()
    
    'If this is the first time the button is firing, we want to reset the button's interval to the repeat rate instead
    ' of the delay rate.
    If tmrUpButton.Interval = Interface.GetKeyboardDelay * 1000 Then
        tmrUpButton.Interval = Interface.GetKeyboardRepeatRate * 1000
    End If
    
    'It's a little counter-intuitive, but the UP button actually moves the control value DOWN
    moveValueDown
    
End Sub

'When the control value is INCREASED, this function is called
Private Sub moveValueUp()
    Value = m_Value + (1 / (10 ^ m_significantDigits))
End Sub

'When the control value is DECREASED, this function is called
Private Sub moveValueDown()
    Value = m_Value - (1 / (10 ^ m_significantDigits))
End Sub

'Any changes to size (or control orientation) must call this function to recalculate the positions of all button and
' slider regions.
Private Sub updateControlLayout()
    
    'First, make sure the back buffer exists and mirrors the current control size
    If m_BackBuffer Is Nothing Then Set m_BackBuffer = New pdDIB
    
    If (m_BackBuffer.getDIBWidth <> UserControl.ScaleWidth) Or (m_BackBuffer.getDIBHeight <> UserControl.ScaleHeight) Then
        m_BackBuffer.createBlank UserControl.ScaleWidth, UserControl.ScaleHeight, 24, m_BackColor
        Debug.Print "Recreating back buffer: " & m_BackBuffer.getDIBWidth & ", " & m_BackBuffer.getDIBHeight
    Else
        GDI_Plus.GDIPlusFillDIBRect m_BackBuffer, 0, 0, m_BackBuffer.getDIBWidth, m_BackBuffer.getDIBHeight, m_BackColor
    End If
    
    'We now need to figure out the position of the up and down buttons.  Their position (obviously) changes based on the
    ' scroll bar's orientation.  Also note that at present, PD makes no special allotments for tiny scrollbars.  They will
    ' not look or behave correctly.
    If m_OrientationHorizontal Then
        
        'In horizontal orientation, the buttons are calculated as squares aligned with the left and right edges of the control.
        With upLeftRect
            .Left = 0
            .Top = 0
            .Bottom = m_BackBuffer.getDIBHeight - 1
            .Right = m_BackBuffer.getDIBHeight - 1
        End With
        
        With downRightRect
            .Left = (m_BackBuffer.getDIBWidth - 1) - upLeftRect.Bottom
            .Top = 0
            .Right = m_BackBuffer.getDIBWidth - 1
            .Bottom = m_BackBuffer.getDIBHeight - 1
        End With
        
    Else
        
        'In vertical orientation, the buttons are calculated as squares aligned with the left and right edges of the control.
        With upLeftRect
            .Left = 0
            .Top = 0
            .Bottom = m_BackBuffer.getDIBWidth - 1
            .Right = m_BackBuffer.getDIBWidth - 1
        End With
        
        With downRightRect
            .Left = 0
            .Right = m_BackBuffer.getDIBWidth - 1
            .Bottom = m_BackBuffer.getDIBHeight - 1
            .Top = .Bottom - (m_BackBuffer.getDIBWidth - 1)
        End With
    
    End If
    
    'If the rects overlap, split the difference between them
    ' TODO: this step isn't relevant for PD, but if it ever becomes relevant, we could add intersect code here.
    
    'With the button rects calculated, use the difference between them to calculate a track rect.
    If m_OrientationHorizontal Then
        With trackRect
            .Left = upLeftRect.Right + 1
            .Top = 0
            .Right = downRightRect.Left '- 1
            .Bottom = m_BackBuffer.getDIBHeight
        End With
    Else
        With trackRect
            .Left = 0
            .Top = upLeftRect.Bottom + 1
            .Right = m_BackBuffer.getDIBWidth
            .Bottom = downRightRect.Top
        End With
    End If
    
    'Figure out the size of the "thumb" slider.  That function will automatically place a call to determineThumbRect.
    determineThumbSize
    
    'No other special preparation is required for this control, so proceed with recreating the back buffer
    redrawBackBuffer True
            
End Sub

Private Sub UserControl_Show()
    m_ControlIsVisible = True
    Debug.Print "showing scroll bar"
    updateControlLayout
End Sub

Private Sub UserControl_WriteProperties(PropBag As PropertyBag)

    'Store all associated properties
    With PropBag
        .WriteProperty "BackColor", m_BackColor, vbWhite
        .WriteProperty "Min", m_Min, 0
        .WriteProperty "Max", m_Max, 10
        .WriteProperty "Value", m_Value, 0
        .WriteProperty "SmallChange", m_SmallChange, 1
        .WriteProperty "LargeChange", m_LargeChange, 1
        .WriteProperty "SignificantDigits", m_significantDigits, 0
        .WriteProperty "OrientationHorizontal", m_OrientationHorizontal, False
    End With
    
End Sub

'External functions can call this to request a redraw.  This is helpful for live-updating theme settings, as in the Preferences dialog.
Public Sub updateAgainstCurrentTheme()
    
    'Make sure the tooltip (if any) is valid
    toolTipManager.updateAgainstCurrentTheme
    
    'Redraw the control, which will also cause a resync against any theme changes
    updateControlLayout
    
End Sub

'Use this function to completely redraw the back buffer from scratch.  Note that this is computationally expensive compared to just flipping the
' existing buffer to the screen, so only redraw the backbuffer if the control state has somehow changed.
Private Sub redrawBackBuffer(Optional ByVal redrawImmediately As Boolean = False)
    
    'Start by erasing the back buffer
    If g_IsProgramRunning Then
        GDI_Plus.GDIPlusFillDIBRect m_BackBuffer, 0, 0, m_BackBuffer.getDIBWidth, m_BackBuffer.getDIBHeight, m_BackColor, 255
    Else
        m_BackBuffer.createBlank UserControl.ScaleWidth, UserControl.ScaleHeight, 24, RGB(255, 255, 255)
    End If
    
    'Next, determine a whole bunch of colors.  Inside the IDE, we will fudge values to prevent errors from the external
    ' themer (and/or GDI+) not being initialized.
    Dim trackBackColor As Long
    Dim thumbBorderColor As Long, thumbFillColor As Long
    Dim upButtonBorderColor As Long, downButtonBorderColor As Long
    Dim upButtonFillColor As Long, downButtonFillColor As Long
    Dim upButtonArrowColor As Long, downButtonArrowColor As Long
    
    If Not (g_Themer Is Nothing) Then
        
        If Me.Enabled Then
        
            trackBackColor = g_Themer.getThemeColor(PDTC_BACKGROUND_CANVAS)
            
            If m_MouseOverThumb Then
                If m_MouseDownThumb Then
                    thumbBorderColor = g_Themer.getThemeColor(PDTC_ACCENT_SHADOW)
                    thumbFillColor = g_Themer.getThemeColor(PDTC_ACCENT_DEFAULT)
                Else
                    thumbBorderColor = g_Themer.getThemeColor(PDTC_ACCENT_HIGHLIGHT)
                    thumbFillColor = g_Themer.getThemeColor(PDTC_BACKGROUND_DEFAULT)
                End If
            Else
                thumbBorderColor = g_Themer.getThemeColor(PDTC_GRAY_SHADOW)
                thumbFillColor = g_Themer.getThemeColor(PDTC_GRAY_HIGHLIGHT)
            End If
            
            If m_MouseOverUpButton Then
                If m_MouseDownUpButton Then
                    upButtonBorderColor = g_Themer.getThemeColor(PDTC_ACCENT_DEFAULT)
                    upButtonArrowColor = g_Themer.getThemeColor(PDTC_TEXT_INVERT)
                    upButtonFillColor = g_Themer.getThemeColor(PDTC_ACCENT_DEFAULT)
                Else
                    upButtonBorderColor = g_Themer.getThemeColor(PDTC_ACCENT_SHADOW)
                    upButtonArrowColor = g_Themer.getThemeColor(PDTC_ACCENT_DEFAULT)
                    upButtonFillColor = g_Themer.getThemeColor(PDTC_BACKGROUND_DEFAULT)
                End If
            Else
                upButtonBorderColor = g_Themer.getThemeColor(PDTC_BACKGROUND_DEFAULT)
                upButtonArrowColor = g_Themer.getThemeColor(PDTC_GRAY_DEFAULT)
                upButtonFillColor = g_Themer.getThemeColor(PDTC_BACKGROUND_DEFAULT)
            End If
            
            If m_MouseOverDownButton Then
                If m_MouseDownDownButton Then
                    downButtonBorderColor = g_Themer.getThemeColor(PDTC_ACCENT_DEFAULT)
                    downButtonArrowColor = g_Themer.getThemeColor(PDTC_TEXT_INVERT)
                    downButtonFillColor = g_Themer.getThemeColor(PDTC_ACCENT_DEFAULT)
                Else
                    downButtonBorderColor = g_Themer.getThemeColor(PDTC_ACCENT_SHADOW)
                    downButtonArrowColor = g_Themer.getThemeColor(PDTC_ACCENT_DEFAULT)
                    downButtonFillColor = g_Themer.getThemeColor(PDTC_BACKGROUND_DEFAULT)
                End If
            Else
                downButtonBorderColor = g_Themer.getThemeColor(PDTC_BACKGROUND_DEFAULT)
                downButtonArrowColor = g_Themer.getThemeColor(PDTC_GRAY_DEFAULT)
                downButtonFillColor = g_Themer.getThemeColor(PDTC_BACKGROUND_DEFAULT)
            End If
        
        Else
            trackBackColor = g_Themer.getThemeColor(PDTC_GRAY_DEFAULT)
            thumbBorderColor = g_Themer.getThemeColor(PDTC_GRAY_SHADOW)
            thumbFillColor = g_Themer.getThemeColor(PDTC_GRAY_SHADOW)
            upButtonBorderColor = g_Themer.getThemeColor(PDTC_GRAY_HIGHLIGHT)
            upButtonFillColor = g_Themer.getThemeColor(PDTC_GRAY_HIGHLIGHT)
            upButtonArrowColor = g_Themer.getThemeColor(PDTC_GRAY_HIGHLIGHT)
            downButtonBorderColor = g_Themer.getThemeColor(PDTC_GRAY_HIGHLIGHT)
            downButtonFillColor = g_Themer.getThemeColor(PDTC_GRAY_HIGHLIGHT)
            downButtonArrowColor = g_Themer.getThemeColor(PDTC_GRAY_HIGHLIGHT)
        End If
        
    Else
        trackBackColor = vbWindowBackground
        thumbBorderColor = RGB(127, 127, 127)
        thumbFillColor = RGB(127, 127, 127)
        upButtonBorderColor = vbBlack
        upButtonFillColor = vbWhite
        upButtonArrowColor = RGB(127, 127, 127)
        downButtonBorderColor = vbBlack
        downButtonFillColor = vbWhite
        downButtonArrowColor = RGB(127, 127, 127)
    End If
    
    'With colors decided (finally!), we can actually draw the damn thing
    
    'Paint all backgrounds and borders first
    If g_IsProgramRunning Then
        
        'Track first
        GDI_Plus.GDIPlusFillDIBRectL m_BackBuffer, trackRect, trackBackColor
        
        'Up button
        GDI_Plus.GDIPlusFillDIBRectL m_BackBuffer, upLeftRect, upButtonFillColor
        GDI_Plus.GDIPlusDrawRectLOutlineToDC m_BackBuffer.getDIBDC, upLeftRect, upButtonBorderColor, , , False
        
        'Down button
        GDI_Plus.GDIPlusFillDIBRectL m_BackBuffer, downRightRect, downButtonFillColor
        GDI_Plus.GDIPlusDrawRectLOutlineToDC m_BackBuffer.getDIBDC, downRightRect, downButtonBorderColor, , , False
        
        'Thumb
        If m_ThumbSize > 0 Then
            GDI_Plus.GDIPlusFillDIBRectF m_BackBuffer, thumbRect, thumbFillColor
            GDI_Plus.GDIPlusDrawRectFOutlineToDC m_BackBuffer.getDIBDC, thumbRect, thumbBorderColor
        End If
        
        'And last, draw the arrows
        'Finally, paint the arrows themselves
        Dim buttonPt1 As POINTFLOAT, buttonPt2 As POINTFLOAT, buttonPt3 As POINTFLOAT
                    
        'Start with the up/left arrow
        If m_OrientationHorizontal Then
            buttonPt1.x = (upLeftRect.Right - upLeftRect.Left) / 2 + FixDPIFloat(2)
            buttonPt1.y = upLeftRect.Top + FixDPIFloat(5)
            
            buttonPt3.x = buttonPt1.x
            buttonPt3.y = upLeftRect.Bottom - FixDPIFloat(5)
            
            buttonPt2.x = buttonPt1.x - FixDPIFloat(3)
            buttonPt2.y = buttonPt1.y + (buttonPt3.y - buttonPt1.y) / 2
        Else
            buttonPt1.x = upLeftRect.Left + FixDPIFloat(5)
            buttonPt1.y = (upLeftRect.Bottom - upLeftRect.Top) / 2 + FixDPIFloat(2)
            
            buttonPt3.x = upLeftRect.Right - FixDPIFloat(5)
            buttonPt3.y = buttonPt1.y
            
            buttonPt2.x = buttonPt1.x + (buttonPt3.x - buttonPt1.x) / 2
            buttonPt2.y = buttonPt1.y - FixDPIFloat(3)
        End If
        
        GDI_Plus.GDIPlusDrawLineToDC m_BackBuffer.getDIBDC, buttonPt1.x, buttonPt1.y, buttonPt2.x, buttonPt2.y, upButtonArrowColor, 255, 2, True, LineCapRound
        GDI_Plus.GDIPlusDrawLineToDC m_BackBuffer.getDIBDC, buttonPt2.x, buttonPt2.y, buttonPt3.x, buttonPt3.y, upButtonArrowColor, 255, 2, True, LineCapRound
                    
        'Next, the down/right-pointing arrow
        If m_OrientationHorizontal Then
            buttonPt1.x = downRightRect.Left + (downRightRect.Right - downRightRect.Left) / 2 - FixDPIFloat(1)
            buttonPt1.y = downRightRect.Top + FixDPIFloat(5)
            
            buttonPt3.x = buttonPt1.x
            buttonPt3.y = downRightRect.Bottom - FixDPIFloat(5)
            
            buttonPt2.x = buttonPt1.x + FixDPIFloat(3)
            buttonPt2.y = buttonPt1.y + (buttonPt3.y - buttonPt1.y) / 2
        Else
            buttonPt1.x = downRightRect.Left + FixDPIFloat(5)
            buttonPt1.y = downRightRect.Top + (downRightRect.Bottom - downRightRect.Top) / 2 - FixDPIFloat(1)
            
            buttonPt3.x = downRightRect.Right - FixDPIFloat(5)
            buttonPt3.y = buttonPt1.y
            
            buttonPt2.x = buttonPt1.x + (buttonPt3.x - buttonPt1.x) / 2
            buttonPt2.y = buttonPt1.y + FixDPIFloat(3)
        End If
        
        GDI_Plus.GDIPlusDrawLineToDC m_BackBuffer.getDIBDC, buttonPt1.x, buttonPt1.y, buttonPt2.x, buttonPt2.y, downButtonArrowColor, 255, 2, True, LineCapRound
        GDI_Plus.GDIPlusDrawLineToDC m_BackBuffer.getDIBDC, buttonPt2.x, buttonPt2.y, buttonPt3.x, buttonPt3.y, downButtonArrowColor, 255, 2, True, LineCapRound
    
    'In the designer, draw a focus rect around the control; this is minimal feedback required for positioning
    Else
    
        Dim tmpRect As RECT
        With tmpRect
            .Left = 0
            .Top = 0
            .Right = m_BackBuffer.getDIBWidth
            .Bottom = m_BackBuffer.getDIBHeight
        End With
        
        DrawFocusRect m_BackBuffer.getDIBDC, tmpRect

    End If
    
    'Paint the buffer to the screen
    If g_IsProgramRunning Then cPainter.requestRepaint redrawImmediately Else BitBlt UserControl.hDC, 0, 0, m_BackBuffer.getDIBWidth, m_BackBuffer.getDIBHeight, m_BackBuffer.getDIBDC, 0, 0, vbSrcCopy

End Sub

'The thumb size is contingent on multiple factors: the size and positioning of the up/down buttons, the available space
' between them, and the range between the control's max/min values.  Call this function to determine a size (BUT NOT A
' POSITION) for the thumb.
Private Sub determineThumbSize()
    
    'Start by determining the maximum available size for the thumb
    Dim maxThumbSize As Single
    
    Debug.Print "TrackRect: " & trackRect.Left & ", " & trackRect.Top & " - " & trackRect.Right & ", " & trackRect.Bottom
    
    If m_OrientationHorizontal Then
        maxThumbSize = trackRect.Right - trackRect.Left
    Else
        maxThumbSize = trackRect.Bottom - trackRect.Top
    End If
    
    'If the max size is less than zero, force it to zero and exit
    If maxThumbSize <= 0 Then
        Debug.Print "WARNING: setting thumb size to zero.  Orientation h=" & m_OrientationHorizontal
        m_ThumbSize = 0
        
    'If the max size is larger than zero, figure out how many discrete, pixel-sized increments there are between
    ' the up/down (or left/right) buttons.
    Else
    
        Dim totalIncrements As Single
        totalIncrements = Abs(m_Max - m_Min)
        
        If totalIncrements <> 0 Then
            m_ThumbSize = maxThumbSize / totalIncrements
            
            'Unlike Windows, we enforce a minimum Thumb size of twice the button size.  This makes the scroll bar a bit
            ' easier to work with, especially on images where the ranges of the scrollbars tend to be *enormous*.
            If m_OrientationHorizontal Then
                If m_ThumbSize < trackRect.Bottom * 2 Then m_ThumbSize = trackRect.Bottom * 2
            Else
                If m_ThumbSize < trackRect.Right * 2 Then m_ThumbSize = trackRect.Right * 2
            End If
            
            'Also, don't let the size exceed the trackbar area
            If m_OrientationHorizontal Then
                If m_ThumbSize > trackRect.Right - trackRect.Left Then m_ThumbSize = trackRect.Right - trackRect.Left
            Else
                If m_ThumbSize > trackRect.Bottom - trackRect.Top Then m_ThumbSize = trackRect.Bottom - trackRect.Top
            End If
            
            Debug.Print "Thumbsize successfully calculated = " & m_ThumbSize
            
        Else
            Debug.Print "WARNING: setting thumb size to zero because scroll max = min"
            m_ThumbSize = 0
        End If
    
    End If
    
    Debug.Print "m_thumbsize = " & m_ThumbSize
    
    'After determining a thumb size, we must always recalculate the current position.
    determineThumbRect
    
End Sub

'Given the control's value, and the (already) determined thumb size, determine its position.
Private Sub determineThumbRect()
    
    If m_BackBuffer Is Nothing Then Exit Sub
    
    'Some coordinates are always the same, regardless of position.
    If m_OrientationHorizontal Then
        thumbRect.Top = 0
        thumbRect.Height = (trackRect.Bottom - trackRect.Top) - 1
    Else
        thumbRect.Left = 0
        thumbRect.Width = (trackRect.Right - trackRect.Left) - 1
    End If
    
    'Next, let's calculate a few special circumstances: max and min values, specifically.
    If m_Value <= m_Min Then
        
        Debug.Print "determineThumbRect taking special action for min value case"
        
        If m_OrientationHorizontal Then
            thumbRect.Left = trackRect.Left
        Else
            thumbRect.Top = trackRect.Top
        End If
    
    ElseIf m_Value >= m_Max Then
    
        Debug.Print "determineThumbRect taking special action for max value case"
    
        If m_OrientationHorizontal Then
            thumbRect.Left = trackRect.Right - m_ThumbSize
        Else
            thumbRect.Top = trackRect.Bottom - m_ThumbSize
        End If
    
    'For any other value, we must calculate the position dynamically
    Else
        
        Debug.Print "determineThumbRect manually calculating thumb position"
        
        'Figure out how many pixels we have to work with, and note that we must subtract the size of the thumb from
        ' the available track space.
        Dim availablePixels As Single
        If m_OrientationHorizontal Then
            availablePixels = ((trackRect.Right - trackRect.Left) - m_ThumbSize) - 1
        Else
            availablePixels = ((trackRect.Bottom - trackRect.Top) - m_ThumbSize) - 1
        End If
        
        'Figure out the ratio between the current value and the max/min range
        Dim curPositionRatio As Double
        
        If m_Max <> m_Min Then
            curPositionRatio = (m_Value - m_Min) / (m_Max - m_Min)
        Else
            curPositionRatio = 0
        End If
        
        If m_OrientationHorizontal Then
            thumbRect.Left = trackRect.Left + curPositionRatio * availablePixels
        Else
            thumbRect.Top = trackRect.Top + curPositionRatio * availablePixels
        End If
        
    End If
    
    'With the position calculated, we can plug in the size parameter without any special knowledge
    If m_OrientationHorizontal Then
        thumbRect.Width = m_ThumbSize
    Else
        thumbRect.Height = m_ThumbSize
    End If
    
    Debug.Print "Thumbrect: " & thumbRect.Left & ", " & thumbRect.Top & " - " & thumbRect.Width & "x" & thumbRect.Height

End Sub

'Due to complex interactions between user controls and PD's translation engine, tooltips require this dedicated function.
' (IMPORTANT NOTE: the tooltip class will handle translations automatically.  Always pass the original English text!)
Public Sub assignTooltip(ByVal newTooltip As String, Optional ByVal newTooltipTitle As String, Optional ByVal newTooltipIcon As TT_ICON_TYPE = TTI_NONE)
    toolTipManager.setTooltip Me.hWnd, Me.containerHwnd, newTooltip, newTooltipTitle, newTooltipIcon
End Sub
