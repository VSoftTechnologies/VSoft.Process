object frmMainForm: TfrmMainForm
  Left = 0
  Top = 0
  Caption = 'Interactive Shell - VSoft.Process demo'
  ClientHeight = 580
  ClientWidth = 800
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Segoe UI'
  Font.Style = []
  Position = poScreenCenter
  OnCloseQuery = FormCloseQuery
  OnCreate = FormCreate
  OnDestroy = FormDestroy
  DesignSize = (
    800
    580)
  TextHeight = 15
  object lblStatus: TLabel
    Left = 8
    Top = 495
    Width = 19
    Height = 15
    Anchors = [akLeft, akRight, akBottom]
    Caption = 'Idle'
  end
  object lstOutput: TListBox
    Left = 8
    Top = 8
    Width = 784
    Height = 481
    Anchors = [akLeft, akTop, akRight, akBottom]
    Font.Charset = DEFAULT_CHARSET
    Font.Color = clWindowText
    Font.Height = -13
    Font.Name = 'Consolas'
    Font.Style = []
    ItemHeight = 15
    ParentFont = False
    TabOrder = 0
  end
  object edInput: TEdit
    Left = 8
    Top = 516
    Width = 697
    Height = 23
    Anchors = [akLeft, akRight, akBottom]
    Font.Charset = DEFAULT_CHARSET
    Font.Color = clWindowText
    Font.Height = -13
    Font.Name = 'Consolas'
    Font.Style = []
    ParentFont = False
    TabOrder = 1
    OnKeyPress = edInputKeyPress
  end
  object btnSend: TButton
    Left = 712
    Top = 515
    Width = 80
    Height = 25
    Anchors = [akRight, akBottom]
    Caption = 'Send'
    Default = True
    TabOrder = 2
    OnClick = btnSendClick
  end
  object btnStart: TButton
    Left = 8
    Top = 548
    Width = 100
    Height = 25
    Anchors = [akLeft, akBottom]
    Caption = 'Start cmd'
    TabOrder = 3
    OnClick = btnStartClick
  end
  object btnStop: TButton
    Left = 114
    Top = 548
    Width = 100
    Height = 25
    Anchors = [akLeft, akBottom]
    Caption = 'Stop'
    TabOrder = 4
    OnClick = btnStopClick
  end
end
