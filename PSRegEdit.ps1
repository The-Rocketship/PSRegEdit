<#
.SYNOPSIS
    PSRegEdit - Modern PowerShell WPF Registry Editor
.DESCRIPTION
    A complete replacement and enhancement for Windows regedit.exe featuring:
    - Native dark mode WPF interface with custom dark menu templates
    - Native regedit.exe window icon
    - Virtualized TreeView for ultra-fast handling of 50,000+ subkeys (HKEY_CLASSES_ROOT)
    - Asynchronous lazy-loaded registry tree structure with Dispatcher message pumping
    - Editable path breadcrumb bar for instant navigation
    - Multi-threaded recursive search panel (Key, Value Name, Data) with regex support
    - Full registry editing (Key creation/deletion/renaming, Value creation/editing for SZ, MULTI_SZ, EXPAND_SZ, DWORD, QWORD, BINARY)
    - Value binary hex viewer/editor
    - Favorites/Bookmarks manager
    - Multi-format Export/Import (.reg and JSON backup)
    - Run as Administrator detection & elevation
#>

# Check and enforce STA (Single Threaded Apartment) mode required for WPF
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $scriptPath = $MyInvocation.MyCommand.Path
    if (-not $scriptPath) { $scriptPath = $PSCommandPath }
    powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "$scriptPath"
    exit
}

# Load Assemblies
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Drawing, System.Windows.Forms

# Ensure AppData folder for PSRegEdit settings
$appDataDir = Join-Path $env:APPDATA "PSRegEdit"
if (-not (Test-Path $appDataDir)) {
    New-Item -ItemType Directory -Path $appDataDir -Force | Out-Null
}
$favoritesPath = Join-Path $appDataDir "favorites.json"

# Helper for Elevation Check
function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

$isAdmin = Test-IsAdmin

# Define modern Dark XAML UI
$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="PSRegEdit - Registry Editor" Height="750" Width="1200"
        WindowStartupLocation="CenterScreen" Background="#181818" Foreground="#E1E1E1">
    
    <Window.Resources>
        <!-- Dark Theme Brushes -->
        <SolidColorBrush x:Key="BgDark" Color="#181818"/>
        <SolidColorBrush x:Key="BgPanel" Color="#202020"/>
        <SolidColorBrush x:Key="BgMenu" Color="#252526"/>
        <SolidColorBrush x:Key="BgMenuHover" Color="#3E3E42"/>
        <SolidColorBrush x:Key="BorderDark" Color="#3F3F46"/>
        <SolidColorBrush x:Key="TextLight" Color="#E1E1E1"/>
        <SolidColorBrush x:Key="TextMuted" Color="#777777"/>
        <SolidColorBrush x:Key="TextDisabled" Color="#656565"/>

        <!-- Custom Dark MenuItem Style & Popup ControlTemplate -->
        <Style TargetType="MenuItem">
            <Setter Property="Background" Value="#252526"/>
            <Setter Property="Foreground" Value="#E1E1E1"/>
            <Setter Property="Padding" Value="8,5"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="MenuItem">
                        <Border x:Name="templateRoot" Background="{TemplateBinding Background}" 
                                BorderBrush="#3F3F46" BorderThickness="{TemplateBinding BorderThickness}" 
                                Padding="{TemplateBinding Padding}">
                            <Grid VerticalAlignment="Center">
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="Auto"/>
                                    <ColumnDefinition Width="*"/>
                                    <ColumnDefinition Width="Auto"/>
                                </Grid.ColumnDefinitions>
                                
                                <ContentPresenter x:Name="Icon" ContentSource="Icon" Margin="0,0,8,0" VerticalAlignment="Center"/>
                                <ContentPresenter Grid.Column="1" x:Name="HeaderHost" ContentSource="Header" VerticalAlignment="Center" RecognizesAccessKey="True"/>
                                <TextBlock Grid.Column="2" x:Name="InputGestureText" Text="{TemplateBinding InputGestureText}" 
                                           Margin="16,0,0,0" Foreground="#888888" VerticalAlignment="Center"/>
                                
                                <Popup x:Name="PART_Popup" AllowsTransparency="True" Focusable="False" 
                                       IsOpen="{Binding IsSubmenuOpen, RelativeSource={RelativeSource TemplatedParent}}" 
                                       Placement="Bottom" PopupAnimation="Fade">
                                    <Border x:Name="SubMenuBorder" Background="#252526" BorderBrush="#3F3F46" BorderThickness="1" Padding="2,4">
                                        <ItemsPresenter x:Name="ItemsPresenter" KeyboardNavigation.DirectionalNavigation="Cycle" 
                                                        Grid.IsSharedSizeScope="True" SnapsToDevicePixels="{TemplateBinding SnapsToDevicePixels}"/>
                                    </Border>
                                </Popup>
                            </Grid>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsHighlighted" Value="True">
                                <Setter TargetName="templateRoot" Property="Background" Value="#3E3E42"/>
                                <Setter Property="Foreground" Value="#FFFFFF"/>
                            </Trigger>
                            <Trigger Property="IsEnabled" Value="False">
                                <Setter Property="Foreground" Value="#656565"/>
                                <Setter TargetName="InputGestureText" Property="Foreground" Value="#444444"/>
                            </Trigger>
                            <Trigger Property="Role" Value="TopLevelHeader">
                                <Setter Property="Padding" Value="10,4"/>
                                <Setter TargetName="PART_Popup" Property="Placement" Value="Bottom"/>
                            </Trigger>
                            <Trigger Property="Role" Value="SubmenuHeader">
                                <Setter TargetName="PART_Popup" Property="Placement" Value="Right"/>
                            </Trigger>
                            <Trigger Property="Role" Value="SubmenuItem">
                                <Setter Property="Padding" Value="10,5"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- ContextMenu Dark Style -->
        <Style TargetType="ContextMenu">
            <Setter Property="Background" Value="#252526"/>
            <Setter Property="Foreground" Value="#E1E1E1"/>
            <Setter Property="BorderBrush" Value="#3F3F46"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="2"/>
        </Style>

        <!-- Menu Bar Style -->
        <Style TargetType="Menu">
            <Setter Property="Background" Value="#252526"/>
            <Setter Property="Foreground" Value="#E1E1E1"/>
        </Style>

        <!-- Button Dark Style -->
        <Style TargetType="Button">
            <Setter Property="Background" Value="#2D2D30"/>
            <Setter Property="Foreground" Value="#E1E1E1"/>
            <Setter Property="BorderBrush" Value="#3F3F46"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="8,4"/>
            <Setter Property="Margin" Value="2"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border Background="{TemplateBinding Background}" 
                                BorderBrush="{TemplateBinding BorderBrush}" 
                                BorderThickness="{TemplateBinding BorderThickness}" 
                                CornerRadius="3" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True">
                                <Setter Property="Background" Value="#3E3E42"/>
                                <Setter Property="BorderBrush" Value="#007ACC"/>
                            </Trigger>
                            <Trigger Property="IsPressed" Value="True">
                                <Setter Property="Background" Value="#007ACC"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>

        <!-- TextBox Dark Style -->
        <Style TargetType="TextBox">
            <Setter Property="Background" Value="#252526"/>
            <Setter Property="Foreground" Value="#E1E1E1"/>
            <Setter Property="CaretBrush" Value="#E1E1E1"/>
            <Setter Property="BorderBrush" Value="#3F3F46"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Padding" Value="4,3"/>
            <Setter Property="VerticalContentAlignment" Value="Center"/>
        </Style>

        <!-- DataGrid Dark Style -->
        <Style TargetType="DataGrid">
            <Setter Property="Background" Value="#1E1E1E"/>
            <Setter Property="RowBackground" Value="#1E1E1E"/>
            <Setter Property="AlternatingRowBackground" Value="#252526"/>
            <Setter Property="Foreground" Value="#E1E1E1"/>
            <Setter Property="GridLinesVisibility" Value="Horizontal"/>
            <Setter Property="HorizontalGridLinesBrush" Value="#2D2D30"/>
            <Setter Property="VerticalGridLinesBrush" Value="Transparent"/>
            <Setter Property="BorderThickness" Value="0"/>
        </Style>
        <Style TargetType="DataGridColumnHeader">
            <Setter Property="Background" Value="#252526"/>
            <Setter Property="Foreground" Value="#E1E1E1"/>
            <Setter Property="Padding" Value="8,6"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
            <Setter Property="BorderBrush" Value="#3F3F46"/>
            <Setter Property="BorderThickness" Value="0,0,1,1"/>
        </Style>
        <Style TargetType="DataGridRow">
            <Style.Triggers>
                <Trigger Property="IsSelected" Value="True">
                    <Setter Property="Background" Value="#094771"/>
                    <Setter Property="Foreground" Value="#FFFFFF"/>
                </Trigger>
                <Trigger Property="IsMouseOver" Value="True">
                    <Setter Property="Background" Value="#2A2D2E"/>
                </Trigger>
            </Style.Triggers>
        </Style>
        <Style TargetType="DataGridCell">
            <Setter Property="Padding" Value="6,4"/>
            <Setter Property="BorderThickness" Value="0"/>
            <Style.Triggers>
                <Trigger Property="IsSelected" Value="True">
                    <Setter Property="Background" Value="#094771"/>
                    <Setter Property="Foreground" Value="#FFFFFF"/>
                </Trigger>
            </Style.Triggers>
        </Style>

        <!-- TreeView Dark Style with Virtualization Support -->
        <Style TargetType="TreeView">
            <Setter Property="Background" Value="#1E1E1E"/>
            <Setter Property="Foreground" Value="#E1E1E1"/>
            <Setter Property="BorderThickness" Value="0"/>
        </Style>
        <Style TargetType="TreeViewItem">
            <Setter Property="Foreground" Value="#E1E1E1"/>
            <Setter Property="ItemsPanel">
                <Setter.Value>
                    <ItemsPanelTemplate>
                        <VirtualizingStackPanel/>
                    </ItemsPanelTemplate>
                </Setter.Value>
            </Setter>
            <Style.Resources>
                <SolidColorBrush x:Key="{x:Static SystemColors.HighlightBrushKey}" Color="#094771"/>
                <SolidColorBrush x:Key="{x:Static SystemColors.HighlightTextBrushKey}" Color="#FFFFFF"/>
                <SolidColorBrush x:Key="{x:Static SystemColors.InactiveSelectionHighlightBrushKey}" Color="#37373D"/>
                <SolidColorBrush x:Key="{x:Static SystemColors.InactiveSelectionHighlightTextBrushKey}" Color="#E1E1E1"/>
            </Style.Resources>
        </Style>
    </Window.Resources>

    <Grid>
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/> <!-- Menu -->
            <RowDefinition Height="Auto"/> <!-- Toolbar -->
            <RowDefinition Height="Auto"/> <!-- Address Bar -->
            <RowDefinition Height="*"/>    <!-- Main Content -->
            <RowDefinition Height="Auto"/> <!-- Search Drawer -->
            <RowDefinition Height="Auto"/> <!-- Statusbar -->
        </Grid.RowDefinitions>

        <!-- Top Menu Bar -->
        <Menu Grid.Row="0">
            <MenuItem Header="_File">
                <MenuItem x:Name="MenuImport" Header="_Import Registry File (.reg)..." InputGestureText="Ctrl+I"/>
                <MenuItem x:Name="MenuExport" Header="_Export Selected Key..." InputGestureText="Ctrl+E"/>
                <Separator Background="#3F3F46"/>
                <MenuItem x:Name="MenuExit" Header="E_xit" InputGestureText="Alt+F4"/>
            </MenuItem>
            <MenuItem Header="_Edit">
                <MenuItem x:Name="MenuNewKey" Header="New _Key" InputGestureText="Ctrl+N"/>
                <MenuItem Header="New _Value">
                    <MenuItem x:Name="MenuNewString" Header="String Value (REG_SZ)"/>
                    <MenuItem x:Name="MenuNewExpandString" Header="Expandable String Value (REG_EXPAND_SZ)"/>
                    <MenuItem x:Name="MenuNewMultiString" Header="Multi-String Value (REG_MULTI_SZ)"/>
                    <MenuItem x:Name="MenuNewDword" Header="DWORD (32-bit) Value (REG_DWORD)"/>
                    <MenuItem x:Name="MenuNewQword" Header="QWORD (64-bit) Value (REG_QWORD)"/>
                    <MenuItem x:Name="MenuNewBinary" Header="Binary Value (REG_BINARY)"/>
                </MenuItem>
                <Separator Background="#3F3F46"/>
                <MenuItem x:Name="MenuDelete" Header="_Delete" InputGestureText="Del"/>
                <Separator Background="#3F3F46"/>
                <MenuItem x:Name="MenuCopyPath" Header="Copy Key _Path" InputGestureText="Ctrl+Shift+C"/>
            </MenuItem>
            <MenuItem Header="_View">
                <MenuItem x:Name="MenuRefresh" Header="_Refresh" InputGestureText="F5"/>
                <MenuItem x:Name="MenuToggleSearch" Header="_Toggle Advanced Search Panel" InputGestureText="Ctrl+F"/>
                <MenuItem x:Name="MenuPermissions" Header="_Permissions / ACL Viewer..."/>
            </MenuItem>
            <MenuItem Header="F_avorites" x:Name="MenuFavoritesRoot">
                <MenuItem x:Name="MenuAddFavorite" Header="_Add to Favorites..."/>
                <Separator Background="#3F3F46"/>
                <!-- Dynamic favorites inserted here -->
            </MenuItem>
            <MenuItem Header="_Help">
                <MenuItem x:Name="MenuAbout" Header="_About PSRegEdit"/>
            </MenuItem>
        </Menu>

        <!-- Main Toolbar -->
        <Border Grid.Row="1" Background="#202020" BorderBrush="#3F3F46" BorderThickness="0,0,0,1" Padding="4,2">
            <StackPanel Orientation="Horizontal">
                <Button x:Name="BtnBack" Content=" [&lt;] " ToolTip="Navigate Back" Width="32" Margin="2,0"/>
                <Button x:Name="BtnForward" Content=" [&gt;] " ToolTip="Navigate Forward" Width="32" Margin="2,0"/>
                <Button x:Name="BtnUp" Content=" [Up] " ToolTip="Parent Key" Margin="2,0"/>
                <Button x:Name="BtnRefresh" Content=" [Refresh] " ToolTip="Refresh (F5)" Margin="2,0"/>
                <Border Width="1" Background="#3F3F46" Margin="6,2"/>
                <Button x:Name="BtnCopyPath" Content=" Copy Path " ToolTip="Copy current path to clipboard" Margin="2,0"/>
                <Button x:Name="BtnSearch" Content=" Advanced Search " ToolTip="Open search panel (Ctrl+F)" Margin="2,0" Background="#007ACC"/>
                <Button x:Name="BtnAddFav" Content=" + Favorite " ToolTip="Add key to favorites" Margin="2,0"/>
                <Border Width="1" Background="#3F3F46" Margin="6,2"/>
                <Button x:Name="BtnExport" Content=" Export " ToolTip="Export current key" Margin="2,0"/>
                <Button x:Name="BtnImport" Content=" Import " ToolTip="Import .reg file" Margin="2,0"/>
                
                <!-- Admin Badge -->
                <Border x:Name="AdminBadge" Background="#28A745" CornerRadius="3" Padding="6,2" Margin="10,0,2,0" VerticalAlignment="Center">
                    <TextBlock x:Name="TxtAdminStatus" Text="ADMIN MODE" Foreground="White" FontWeight="Bold" FontSize="11"/>
                </Border>
            </StackPanel>
        </Border>

        <!-- Address Bar -->
        <Border Grid.Row="2" Background="#252526" BorderBrush="#3F3F46" BorderThickness="0,0,0,1" Padding="6,4">
            <Grid>
                <Grid.ColumnDefinitions>
                    <ColumnDefinition Width="Auto"/>
                    <ColumnDefinition Width="*"/>
                    <ColumnDefinition Width="Auto"/>
                </Grid.ColumnDefinitions>
                <TextBlock Grid.Column="0" Text="Path:" VerticalAlignment="Center" Margin="4,0,8,0" Foreground="#999999" FontWeight="SemiBold"/>
                <TextBox Grid.Column="1" x:Name="TxtAddressPath" Text="Computer" FontFamily="Consolas" FontSize="13" VerticalAlignment="Center"/>
                <Button Grid.Column="2" x:Name="BtnGoAddress" Content=" Go " Margin="6,0,0,0" Padding="12,3"/>
            </Grid>
        </Border>

        <!-- Main Tree & Values Grid -->
        <Grid Grid.Row="3">
            <Grid.ColumnDefinitions>
                <ColumnDefinition Width="320" MinWidth="180"/>
                <ColumnDefinition Width="4"/>
                <ColumnDefinition Width="*"/>
            </Grid.ColumnDefinitions>

            <!-- Virtualized Registry TreeView -->
            <Border Grid.Column="0" Background="#1E1E1E">
                <TreeView x:Name="RegTreeView" Margin="2"
                          VirtualizingStackPanel.IsVirtualizing="True"
                          VirtualizingStackPanel.VirtualizationMode="Recycling"
                          ScrollViewer.CanContentScroll="True">
                    <TreeView.ItemsPanel>
                        <ItemsPanelTemplate>
                            <VirtualizingStackPanel/>
                        </ItemsPanelTemplate>
                    </TreeView.ItemsPanel>
                    <TreeView.ItemTemplate>
                        <HierarchicalDataTemplate ItemsSource="{Binding Children}">
                            <StackPanel Orientation="Horizontal" Margin="0,1">
                                <TextBlock Text="{Binding Icon}" Margin="0,0,6,0" Foreground="#E5C07B"/>
                                <TextBlock Text="{Binding Name}" Foreground="#E1E1E1"/>
                            </StackPanel>
                        </HierarchicalDataTemplate>
                    </TreeView.ItemTemplate>
                </TreeView>
            </Border>

            <!-- Grid Splitter -->
            <GridSplitter Grid.Column="1" Width="4" HorizontalAlignment="Stretch" Background="#2D2D30" ResizeBehavior="PreviousAndNext"/>

            <!-- Values DataGrid & Quick Filter -->
            <Grid Grid.Column="2" Background="#1E1E1E">
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="*"/>
                </Grid.RowDefinitions>

                <!-- Value Filter Bar -->
                <Border Grid.Row="0" Background="#202020" BorderBrush="#3F3F46" BorderThickness="0,0,0,1" Padding="6,3">
                    <Grid>
                        <Grid.ColumnDefinitions>
                            <ColumnDefinition Width="Auto"/>
                            <ColumnDefinition Width="*"/>
                            <ColumnDefinition Width="Auto"/>
                        </Grid.ColumnDefinitions>
                        <TextBlock Grid.Column="0" Text="Filter Values:" VerticalAlignment="Center" Foreground="#999999" Margin="0,0,6,0"/>
                        <TextBox Grid.Column="1" x:Name="TxtValueFilter" Padding="3,2" Margin="0,0,6,0"/>
                        <TextBlock Grid.Column="2" x:Name="TxtValueCount" Text="0 items" VerticalAlignment="Center" Foreground="#999999" Margin="4,0"/>
                    </Grid>
                </Border>

                <!-- Values DataGrid -->
                <DataGrid Grid.Row="1" x:Name="ValuesDataGrid" AutoGenerateColumns="False" IsReadOnly="True" 
                          SelectionMode="Single" GridLinesVisibility="Horizontal" HeadersVisibility="Column">
                    <DataGrid.ContextMenu>
                        <ContextMenu x:Name="DataGridContextMenu">
                            <MenuItem x:Name="CtxModify" Header="_Modify..." FontWeight="Bold"/>
                            <Separator Background="#3F3F46"/>
                            <MenuItem x:Name="CtxDeleteValue" Header="_Delete"/>
                            <Separator Background="#3F3F46"/>
                            <MenuItem x:Name="CtxCopyValName" Header="Copy Name"/>
                            <MenuItem x:Name="CtxCopyValData" Header="Copy Data"/>
                        </ContextMenu>
                    </DataGrid.ContextMenu>
                    <DataGrid.Columns>
                        <DataGridTextColumn Header="Name" Binding="{Binding Name}" Width="220"/>
                        <DataGridTextColumn Header="Type" Binding="{Binding TypeDisplay}" Width="150"/>
                        <DataGridTextColumn Header="Data" Binding="{Binding DataDisplay}" Width="*"/>
                        <DataGridTextColumn Header="Size" Binding="{Binding SizeDisplay}" Width="80"/>
                    </DataGrid.Columns>
                </DataGrid>
            </Grid>
        </Grid>

        <!-- Advanced Search Drawer Panel -->
        <Border Grid.Row="4" x:Name="SearchDrawer" Background="#202020" BorderBrush="#007ACC" BorderThickness="0,2,0,0" Height="220" Visibility="Collapsed">
            <Grid Margin="6">
                <Grid.RowDefinitions>
                    <RowDefinition Height="Auto"/>
                    <RowDefinition Height="*"/>
                </Grid.RowDefinitions>

                <Grid Grid.Row="0" Margin="0,0,0,4">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="*"/>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="Auto"/>
                        <ColumnDefinition Width="Auto"/>
                    </Grid.ColumnDefinitions>
                    <TextBlock Grid.Column="0" Text="Search String:" VerticalAlignment="Center" Margin="0,0,6,0" Foreground="#E1E1E1" FontWeight="SemiBold"/>
                    <TextBox Grid.Column="1" x:Name="TxtSearchQuery" Margin="0,0,6,0"/>
                    <CheckBox Grid.Column="2" x:Name="ChkSearchKeys" Content="Keys" IsChecked="True" Foreground="#E1E1E1" VerticalAlignment="Center" Margin="4,0"/>
                    <CheckBox Grid.Column="3" x:Name="ChkSearchValues" Content="Values" IsChecked="True" Foreground="#E1E1E1" VerticalAlignment="Center" Margin="4,0"/>
                    <CheckBox Grid.Column="4" x:Name="ChkSearchData" Content="Data" IsChecked="True" Foreground="#E1E1E1" VerticalAlignment="Center" Margin="4,0"/>
                </Grid>

                <Grid Grid.Row="1">
                    <Grid.RowDefinitions>
                        <RowDefinition Height="Auto"/>
                        <RowDefinition Height="*"/>
                    </Grid.RowDefinitions>

                    <StackPanel Grid.Row="0" Orientation="Horizontal" Margin="0,0,0,4">
                        <Button x:Name="BtnRunSearch" Content=" Find Next / All " Background="#007ACC" Foreground="White" Padding="12,4"/>
                        <Button x:Name="BtnStopSearch" Content=" Stop " Margin="4,0" Padding="8,4" IsEnabled="False"/>
                        <CheckBox x:Name="ChkSearchRegex" Content="Regex" Foreground="#E1E1E1" VerticalAlignment="Center" Margin="10,0"/>
                        <CheckBox x:Name="ChkSearchCurrentKeyOnly" Content="Current Key Only" Foreground="#E1E1E1" VerticalAlignment="Center" Margin="10,0"/>
                        <TextBlock x:Name="TxtSearchProgress" Text="Ready" Foreground="#999999" VerticalAlignment="Center" Margin="15,0"/>
                        <Button x:Name="BtnCloseSearch" Content=" X Close Panel " HorizontalAlignment="Right" Margin="20,0,0,0"/>
                    </StackPanel>

                    <!-- Search Results Grid -->
                    <DataGrid Grid.Row="1" x:Name="SearchResultsGrid" AutoGenerateColumns="False" IsReadOnly="True" SelectionMode="Single">
                        <DataGrid.Columns>
                            <DataGridTextColumn Header="Key Path" Binding="{Binding KeyPath}" Width="350"/>
                            <DataGridTextColumn Header="Match Type" Binding="{Binding MatchType}" Width="100"/>
                            <DataGridTextColumn Header="Value Name" Binding="{Binding Name}" Width="150"/>
                            <DataGridTextColumn Header="Data" Binding="{Binding DataDisplay}" Width="*"/>
                        </DataGrid.Columns>
                    </DataGrid>
                </Grid>
            </Grid>
        </Border>

        <!-- Statusbar -->
        <StatusBar Grid.Row="5" Background="#007ACC" Foreground="White" Padding="6,3">
            <StatusBarItem HorizontalAlignment="Left">
                <TextBlock x:Name="TxtStatus" Text="Ready" Foreground="White" FontSize="12"/>
            </StatusBarItem>
            <StatusBarItem HorizontalAlignment="Right">
                <TextBlock x:Name="TxtSelectionInfo" Text="Computer" Foreground="White" FontSize="12"/>
            </StatusBarItem>
        </StatusBar>
    </Grid>
</Window>
"@

# Helper to read XAML
$reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($xaml))
$window = [System.Windows.Markup.XamlReader]::Load($reader)

# Set native regedit.exe Icon for Window
try {
    $regExePath = Join-Path $env:SystemRoot "regedit.exe"
    if (Test-Path $regExePath) {
        $regIcon = [System.Drawing.Icon]::ExtractAssociatedIcon($regExePath)
        if ($regIcon) {
            $window.Icon = [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon(
                $regIcon.Handle,
                [System.Windows.Int32Rect]::Empty,
                [System.Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions()
            )
        }
    }
} catch {}

# Connect UI Controls
$RegTreeView = $window.FindName("RegTreeView")
$ValuesDataGrid = $window.FindName("ValuesDataGrid")
$SearchResultsGrid = $window.FindName("SearchResultsGrid")
$TxtAddressPath = $window.FindName("TxtAddressPath")
$BtnGoAddress = $window.FindName("BtnGoAddress")
$TxtValueFilter = $window.FindName("TxtValueFilter")
$TxtValueCount = $window.FindName("TxtValueCount")
$TxtStatus = $window.FindName("TxtStatus")
$TxtSelectionInfo = $window.FindName("TxtSelectionInfo")
$AdminBadge = $window.FindName("AdminBadge")
$TxtAdminStatus = $window.FindName("TxtAdminStatus")

# Buttons
$BtnBack = $window.FindName("BtnBack")
$BtnForward = $window.FindName("BtnForward")
$BtnUp = $window.FindName("BtnUp")
$BtnRefresh = $window.FindName("BtnRefresh")
$BtnCopyPath = $window.FindName("BtnCopyPath")
$BtnSearch = $window.FindName("BtnSearch")
$BtnAddFav = $window.FindName("BtnAddFav")
$BtnExport = $window.FindName("BtnExport")
$BtnImport = $window.FindName("BtnImport")

# Search controls
$SearchDrawer = $window.FindName("SearchDrawer")
$TxtSearchQuery = $window.FindName("TxtSearchQuery")
$ChkSearchKeys = $window.FindName("ChkSearchKeys")
$ChkSearchValues = $window.FindName("ChkSearchValues")
$ChkSearchData = $window.FindName("ChkSearchData")
$ChkSearchRegex = $window.FindName("ChkSearchRegex")
$ChkSearchCurrentKeyOnly = $window.FindName("ChkSearchCurrentKeyOnly")
$BtnRunSearch = $window.FindName("BtnRunSearch")
$BtnStopSearch = $window.FindName("BtnStopSearch")
$BtnCloseSearch = $window.FindName("BtnCloseSearch")
$TxtSearchProgress = $window.FindName("TxtSearchProgress")

# Menu Items
$MenuImport = $window.FindName("MenuImport")
$MenuExport = $window.FindName("MenuExport")
$MenuExit = $window.FindName("MenuExit")
$MenuNewKey = $window.FindName("MenuNewKey")
$MenuNewString = $window.FindName("MenuNewString")
$MenuNewExpandString = $window.FindName("MenuNewExpandString")
$MenuNewMultiString = $window.FindName("MenuNewMultiString")
$MenuNewDword = $window.FindName("MenuNewDword")
$MenuNewQword = $window.FindName("MenuNewQword")
$MenuNewBinary = $window.FindName("MenuNewBinary")
$MenuDelete = $window.FindName("MenuDelete")
$MenuCopyPath = $window.FindName("MenuCopyPath")
$MenuRefresh = $window.FindName("MenuRefresh")
$MenuToggleSearch = $window.FindName("MenuToggleSearch")
$MenuPermissions = $window.FindName("MenuPermissions")
$MenuFavoritesRoot = $window.FindName("MenuFavoritesRoot")
$MenuAddFavorite = $window.FindName("MenuAddFavorite")
$MenuAbout = $window.FindName("MenuAbout")

# Context Menu Items
$CtxModify = $window.FindName("CtxModify")
$CtxDeleteValue = $window.FindName("CtxDeleteValue")
$CtxCopyValName = $window.FindName("CtxCopyValName")
$CtxCopyValData = $window.FindName("CtxCopyValData")

# Admin Badge Setup
if (-not $isAdmin) {
    $AdminBadge.Background = [System.Windows.Media.Brushes]::OrangeRed
    $TxtAdminStatus.Text = "READ-ONLY (NON-ADMIN)"
    $TxtAdminStatus.ToolTip = "Launch PSRegEdit as Administrator to modify protected keys"
}

# App State Variables
$global:NavHistory = [System.Collections.Generic.List[string]]::new()
$global:NavHistoryIndex = -1
$global:CurrentSelectedNode = $null
$global:CurrentValuesList = [System.Collections.Generic.List[PSObject]]::new()

# Data Models
class RegNode {
    [string]$Name
    [string]$Path
    [string]$Icon
    [System.Collections.ObjectModel.ObservableCollection[RegNode]]$Children
    [bool]$IsDummy
    [bool]$IsExpanded

    RegNode([string]$name, [string]$path, [string]$icon) {
        $this.Name = $name
        $this.Path = $path
        $this.Icon = $icon
        $this.IsDummy = $false
        $this.IsExpanded = $false
        $this.Children = [System.Collections.ObjectModel.ObservableCollection[RegNode]]::new()
    }
}

# Root Hives Definition
$RootHives = @(
    @{ Name = "HKEY_CLASSES_ROOT"; Short = "HKCR"; Hive = [Microsoft.Win32.Registry]::ClassesRoot },
    @{ Name = "HKEY_CURRENT_USER"; Short = "HKCU"; Hive = [Microsoft.Win32.Registry]::CurrentUser },
    @{ Name = "HKEY_LOCAL_MACHINE"; Short = "HKLM"; Hive = [Microsoft.Win32.Registry]::LocalMachine },
    @{ Name = "HKEY_USERS"; Short = "HKU"; Hive = [Microsoft.Win32.Registry]::Users },
    @{ Name = "HKEY_CURRENT_CONFIG"; Short = "HKCC"; Hive = [Microsoft.Win32.Registry]::CurrentConfig }
)

# Parse Registry Path into Hive and SubKey
function Split-RegistryPath {
    param([string]$path)
    
    $cleanPath = $path -replace "^Computer\\?", "" -replace "^Computer", "" -replace "^\\+", ""
    $parts = $cleanPath.Split('\', 2, [StringSplitOptions]::RemoveEmptyEntries)
    
    if ($parts.Count -eq 0) { return $null }
    
    $hiveStr = $parts[0].ToUpper()
    $subKey = if ($parts.Count -gt 1) { $parts[1] } else { "" }
    
    $hive = switch ($hiveStr) {
        "HKEY_CLASSES_ROOT"  { [Microsoft.Win32.Registry]::ClassesRoot }
        "HKCR"               { [Microsoft.Win32.Registry]::ClassesRoot }
        "HKEY_CURRENT_USER"  { [Microsoft.Win32.Registry]::CurrentUser }
        "HKCU"               { [Microsoft.Win32.Registry]::CurrentUser }
        "HKEY_LOCAL_MACHINE" { [Microsoft.Win32.Registry]::LocalMachine }
        "HKLM"               { [Microsoft.Win32.Registry]::LocalMachine }
        "HKEY_USERS"         { [Microsoft.Win32.Registry]::Users }
        "HKU"                { [Microsoft.Win32.Registry]::Users }
        "HKEY_CURRENT_CONFIG"{ [Microsoft.Win32.Registry]::CurrentConfig }
        "HKCC"               { [Microsoft.Win32.Registry]::CurrentConfig }
        default              { $null }
    }
    
    return @{ Hive = $hive; SubKey = $subKey; HiveName = $hiveStr }
}

# Open Registry Key Safely
function Get-RegKeyObject {
    param(
        [string]$fullPath,
        [bool]$writable = $false
    )
    
    $parsed = Split-RegistryPath -path $fullPath
    if (-not $parsed -or -not $parsed.Hive) { return $null }
    
    try {
        if ([string]::IsNullOrEmpty($parsed.SubKey)) {
            return $parsed.Hive
        }
        return $parsed.Hive.OpenSubKey($parsed.SubKey, $writable)
    } catch {
        return $null
    }
}

# Populate Root Hives in TreeView
function Initialize-Tree {
    $RegTreeView.Items.Clear()
    $computerNode = [RegNode]::new("Computer", "Computer", "[PC]")
    
    foreach ($h in $RootHives) {
        $node = [RegNode]::new($h.Name, "Computer\" + $h.Name, "[Hive]")
        # Add dummy child for lazy loading
        $dummy = [RegNode]::new("Loading...", "", "")
        $dummy.IsDummy = $true
        $node.Children.Add($dummy)
        $computerNode.Children.Add($node)
    }
    
    $RegTreeView.Items.Add($computerNode)
    $computerNode.IsExpanded = $true
}

# Ultra-Fast Virtualized & Paged Lazy Loader for Huge Registry Keys
function Expand-RegNode {
    param([RegNode]$node)
    
    if (-not $node -or $node.Path -eq "Computer") { return }
    
    # Remove dummy if present
    if ($node.Children.Count -eq 1 -and $node.Children[0].IsDummy) {
        $node.Children.Clear()
        
        $regKey = Get-RegKeyObject -fullPath $node.Path -writable $false
        if ($regKey) {
            try {
                $subKeyNames = $regKey.GetSubKeyNames()
                $total = $subKeyNames.Count
                
                # Batch population with WPF Dispatcher pumping every 200 items so UI thread NEVER freezes
                for ($i = 0; $i -lt $total; $i++) {
                    $subName = $subKeyNames[$i]
                    $childPath = $node.Path + "\" + $subName
                    $childNode = [RegNode]::new($subName, $childPath, "[Key]")
                    
                    $dummy = [RegNode]::new("Loading...", "", "")
                    $dummy.IsDummy = $true
                    $childNode.Children.Add($dummy)
                    
                    $node.Children.Add($childNode)
                    
                    # Pump WPF UI dispatcher every 200 subkeys to keep UI 100% responsive
                    if ($i -gt 0 -and ($i % 200) -eq 0) {
                        [System.Windows.Threading.Dispatcher]::CurrentDispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Background)
                    }
                }
            } catch {
                $TxtStatus.Text = "Access Denied reading subkeys of $($node.Path)"
            } finally {
                if ($regKey -ne [Microsoft.Win32.Registry]::CurrentUser -and 
                    $regKey -ne [Microsoft.Win32.Registry]::LocalMachine -and 
                    $regKey -ne [Microsoft.Win32.Registry]::ClassesRoot -and 
                    $regKey -ne [Microsoft.Win32.Registry]::Users -and 
                    $regKey -ne [Microsoft.Win32.Registry]::CurrentConfig) {
                    $regKey.Close()
                }
            }
        }
    }
}

# Display Values for Selected Key in DataGrid
function Get-KeyValues {
    param([string]$path)
    
    $global:CurrentValuesList.Clear()
    $ValuesDataGrid.ItemsSource = $null
    
    if ([string]::IsNullOrEmpty($path) -or $path -eq "Computer") {
        $TxtValueCount.Text = "0 items"
        return
    }
    
    $regKey = Get-RegKeyObject -fullPath $path -writable $false
    if (-not $regKey) {
        $TxtStatus.Text = "Unable to open key: $path (Permission denied or non-existent)"
        return
    }
    
    try {
        $valNames = $regKey.GetValueNames()
        foreach ($vName in $valNames) {
            $displayName = if ([string]::IsNullOrEmpty($vName)) { "(Default)" } else { $vName }
            $vType = $regKey.GetValueKind($vName)
            $vVal = $regKey.GetValue($vName, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            
            $typeStr = switch ($vType) {
                "String"        { "REG_SZ" }
                "ExpandString"  { "REG_EXPAND_SZ" }
                "MultiString"   { "REG_MULTI_SZ" }
                "DWord"         { "REG_DWORD" }
                "QWord"         { "REG_QWORD" }
                "Binary"        { "REG_BINARY" }
                "None"          { "REG_NONE" }
                default         { $vType.ToString() }
            }
            
            # Format Data Display
            $dataDisplay = ""
            $sizeDisplay = "-"
            
            if ($null -ne $vVal) {
                if ($vType -eq "Binary") {
                    $bytes = [byte[]]$vVal
                    $sizeDisplay = "$($bytes.Length) bytes"
                    $hexParts = ($bytes | Select-Object -First 16 | ForEach-Object { "{0:X2}" -f $_ }) -join " "
                    if ($bytes.Length -gt 16) { $hexParts += " ..." }
                    $dataDisplay = $hexParts
                } elseif ($vType -eq "MultiString") {
                    $dataDisplay = ($vVal -join " \0 ")
                    $sizeDisplay = "$($vVal.Count) lines"
                } elseif ($vType -eq "DWord") {
                    $dataDisplay = "0x{0:x8} ({0})" -f [uint32]$vVal
                } elseif ($vType -eq "QWord") {
                    $dataDisplay = "0x{0:x16} ({0})" -f [uint64]$vVal
                } else {
                    $dataDisplay = $vVal.ToString()
                }
            } else {
                $dataDisplay = "(value not set)"
            }
            
            $item = [PSCustomObject]@{
                RawName     = $vName
                Name        = $displayName
                TypeDisplay = $typeStr
                TypeKind    = $vType
                RawData     = $vVal
                DataDisplay = $dataDisplay
                SizeDisplay = $sizeDisplay
            }
            
            $global:CurrentValuesList.Add($item)
        }
    } catch {
        $TxtStatus.Text = "Error reading key values: $_"
    } finally {
        if ($regKey -ne [Microsoft.Win32.Registry]::CurrentUser -and 
            $regKey -ne [Microsoft.Win32.Registry]::LocalMachine -and 
            $regKey -ne [Microsoft.Win32.Registry]::ClassesRoot -and 
            $regKey -ne [Microsoft.Win32.Registry]::Users -and 
            $regKey -ne [Microsoft.Win32.Registry]::CurrentConfig) {
            $regKey.Close()
        }
    }
    
    Invoke-ValueFilter
}

# Apply Filter Box to Values DataGrid
function Invoke-ValueFilter {
    $filterText = $TxtValueFilter.Text.Trim()
    if ([string]::IsNullOrEmpty($filterText)) {
        $ValuesDataGrid.ItemsSource = $global:CurrentValuesList
        $TxtValueCount.Text = "$($global:CurrentValuesList.Count) items"
    } else {
        $filtered = $global:CurrentValuesList | Where-Object { 
            $_.Name -like "*$filterText*" -or $_.DataDisplay -like "*$filterText*" -or $_.TypeDisplay -like "*$filterText*"
        }
        $ValuesDataGrid.ItemsSource = $filtered
        $count = if ($filtered) { $filtered.Count } else { 0 }
        $TxtValueCount.Text = "$count / $($global:CurrentValuesList.Count) items"
    }
}

# Tree Selection Event Handler
$RegTreeView.add_SelectedItemChanged({
    param($src, $evt)
    
    $selectedNode = $RegTreeView.SelectedItem
    if ($selectedNode -is [RegNode]) {
        $global:CurrentSelectedNode = $selectedNode
        $TxtAddressPath.Text = $selectedNode.Path
        $TxtSelectionInfo.Text = $selectedNode.Path
        
        # Expand child node lazy
        Expand-RegNode -node $selectedNode
        Get-KeyValues -path $selectedNode.Path
        
        # History
        if ($global:NavHistoryIndex -lt 0 -or $global:NavHistory[$global:NavHistoryIndex] -ne $selectedNode.Path) {
            if ($global:NavHistoryIndex + 1 -lt $global:NavHistory.Count) {
                $global:NavHistory.RemoveRange($global:NavHistoryIndex + 1, $global:NavHistory.Count - ($global:NavHistoryIndex + 1))
            }
            $global:NavHistory.Add($selectedNode.Path)
            $global:NavHistoryIndex = $global:NavHistory.Count - 1
        }
    }
})

# Filter Text Change Event
$TxtValueFilter.add_TextChanged({ Invoke-ValueFilter })

# Tree Expansion Handler via WPF RoutedEvent
$RegTreeView.AddHandler(
    [System.Windows.Controls.TreeViewItem]::ExpandedEvent, 
    [System.Windows.RoutedEventHandler]{
        param($src, $evt)
        $tvi = $evt.OriginalSource
        if ($tvi -and $tvi.DataContext -is [RegNode]) {
            Expand-RegNode -node $tvi.DataContext
        }
    }
)

# Navigate To Path via Address Bar
function Invoke-NavigateToPath {
    param([string]$targetPath)
    
    $clean = $targetPath.Trim()
    $TxtAddressPath.Text = $clean
    Get-KeyValues -path $clean
    $TxtStatus.Text = "Navigated to: $clean"
}

$BtnGoAddress.add_Click({ Invoke-NavigateToPath -targetPath $TxtAddressPath.Text })
$TxtAddressPath.add_KeyDown({
    param($src, $evt)
    if ($evt.Key -eq 'Return') { Invoke-NavigateToPath -targetPath $TxtAddressPath.Text }
})

# Navigation Buttons (Back / Forward / Up / Refresh)
$BtnBack.add_Click({
    if ($global:NavHistoryIndex -gt 0) {
        $global:NavHistoryIndex--
        $path = $global:NavHistory[$global:NavHistoryIndex]
        Invoke-NavigateToPath -targetPath $path
    }
})

$BtnForward.add_Click({
    if ($global:NavHistoryIndex + 1 -lt $global:NavHistory.Count) {
        $global:NavHistoryIndex++
        $path = $global:NavHistory[$global:NavHistoryIndex]
        Invoke-NavigateToPath -targetPath $path
    }
})

$BtnUp.add_Click({
    $curPath = $TxtAddressPath.Text
    if ([string]::IsNullOrEmpty($curPath) -or $curPath -eq "Computer") { return }
    $lastSlash = $curPath.LastIndexOf('\')
    if ($lastSlash -gt 0) {
        $parentPath = $curPath.Substring(0, $lastSlash)
        Invoke-NavigateToPath -targetPath $parentPath
    } else {
        Invoke-NavigateToPath -targetPath "Computer"
    }
})

$BtnRefresh.add_Click({
    if ($global:CurrentSelectedNode) {
        $global:CurrentSelectedNode.Children.Clear()
        $dummy = [RegNode]::new("Loading...", "", "")
        $dummy.IsDummy = $true
        $global:CurrentSelectedNode.Children.Add($dummy)
        Expand-RegNode -node $global:CurrentSelectedNode
        Get-KeyValues -path $global:CurrentSelectedNode.Path
        $TxtStatus.Text = "Refreshed $($global:CurrentSelectedNode.Path)"
    }
})
$MenuRefresh.add_Click({ $BtnRefresh.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Button]::ClickEvent))) })

# Copy Path
$BtnCopyPath.add_Click({
    if ($TxtAddressPath.Text) {
        [System.Windows.Clipboard]::SetText($TxtAddressPath.Text)
        $TxtStatus.Text = "Copied path to clipboard!"
    }
})
$MenuCopyPath.add_Click({ $BtnCopyPath.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Button]::ClickEvent))) })

# Copy Value Name & Copy Value Data Context Menu Handlers
$CtxCopyValName.add_Click({
    $selectedVal = $ValuesDataGrid.SelectedItem
    if ($selectedVal -and $selectedVal.Name) {
        [System.Windows.Clipboard]::SetText($selectedVal.Name)
        $TxtStatus.Text = "Copied value name to clipboard!"
    }
})

$CtxCopyValData.add_Click({
    $selectedVal = $ValuesDataGrid.SelectedItem
    if ($selectedVal -and $selectedVal.DataDisplay) {
        [System.Windows.Clipboard]::SetText($selectedVal.DataDisplay)
        $TxtStatus.Text = "Copied value data to clipboard!"
    }
})

# Show Input Dialog Helper
function Show-InputDialog {
    param(
        [string]$title,
        [string]$prompt,
        [string]$defaultValue = ""
    )
    
    $dlgXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        Title="$title" Height="180" Width="420" WindowStartupLocation="CenterOwner"
        Background="#202020" Foreground="#E1E1E1" ResizeMode="NoResize">
    <Grid Margin="12">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <TextBlock Grid.Row="0" Text="$prompt" Foreground="#E1E1E1" Margin="0,0,0,8" TextWrapping="Wrap"/>
        <TextBox Grid.Row="1" x:Name="DlgInput" Text="$defaultValue" Background="#252526" Foreground="#E1E1E1" Padding="4" Margin="0,0,0,12"/>
        <StackPanel Grid.Row="2" Orientation="Horizontal" HorizontalAlignment="Right">
            <Button x:Name="DlgOk" Content=" OK " Width="80" Margin="4,0" Background="#007ACC" Foreground="White"/>
            <Button x:Name="DlgCancel" Content=" Cancel " Width="80" Margin="4,0" Background="#3E3E42" Foreground="White"/>
        </StackPanel>
    </Grid>
</Window>
"@
    $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($dlgXaml))
    $dlg = [System.Windows.Markup.XamlReader]::Load($reader)
    $dlg.Owner = $window
    
    $txtInput = $dlg.FindName("DlgInput")
    $btnOk = $dlg.FindName("DlgOk")
    $btnCancel = $dlg.FindName("BtnCancel")
    
    $script:dialogResult = $null
    $btnOk.add_Click({
        $script:dialogResult = $txtInput.Text
        $dlg.DialogResult = $true
        $dlg.Close()
    })
    $btnCancel.add_Click({
        $dlg.DialogResult = $false
        $dlg.Close()
    })
    
    $txtInput.Focus() | Out-Null
    $dlg.ShowDialog() | Out-Null
    return $script:dialogResult
}

# Create New Key Handler
$MenuNewKey.add_Click({
    $curPath = $TxtAddressPath.Text
    if ([string]::IsNullOrEmpty($curPath) -or $curPath -eq "Computer") {
        [System.Windows.MessageBox]::Show("Select a registry hive or parent key first.", "PSRegEdit", 'OK', 'Warning')
        return
    }
    
    $keyName = Show-InputDialog -title "New Key" -prompt "Enter name for the new key:" -defaultValue "New Key #1"
    if ([string]::IsNullOrWhiteSpace($keyName)) { return }
    
    $regKey = Get-RegKeyObject -fullPath $curPath -writable $true
    if ($regKey) {
        try {
            $newSub = $regKey.CreateSubKey($keyName)
            if ($newSub) { $newSub.Close() }
            $TxtStatus.Text = "Created new key: $keyName in $curPath"
            # Refresh tree
            $BtnRefresh.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Button]::ClickEvent)))
        } catch {
            [System.Windows.MessageBox]::Show("Failed to create key: $_", "Error", 'OK', 'Error')
        } finally {
            if ($regKey -ne [Microsoft.Win32.Registry]::CurrentUser -and 
                $regKey -ne [Microsoft.Win32.Registry]::LocalMachine) { $regKey.Close() }
        }
    } else {
        [System.Windows.MessageBox]::Show("Unable to open parent key for writing.", "Error", 'OK', 'Error')
    }
})

# Generic New Value Creation Handler
function Add-NewRegistryValue {
    param(
        [string]$typeStr,
        [Microsoft.Win32.RegistryValueKind]$kind,
        $defaultVal
    )
    
    $curPath = $TxtAddressPath.Text
    if ([string]::IsNullOrEmpty($curPath) -or $curPath -eq "Computer") { return }
    
    $valName = Show-InputDialog -title "New $typeStr Value" -prompt "Enter value name:" -defaultValue "NewValue1"
    if ($null -eq $valName) { return }
    
    $regKey = Get-RegKeyObject -fullPath $curPath -writable $true
    if ($regKey) {
        try {
            $regKey.SetValue($valName, $defaultVal, $kind)
            $TxtStatus.Text = "Created $typeStr value: '$valName'"
            Get-KeyValues -path $curPath
        } catch {
            [System.Windows.MessageBox]::Show("Failed to create value: $_", "Error", 'OK', 'Error')
        } finally {
            if ($regKey -ne [Microsoft.Win32.Registry]::CurrentUser -and 
                $regKey -ne [Microsoft.Win32.Registry]::LocalMachine) { $regKey.Close() }
        }
    }
}

$MenuNewString.add_Click({ Add-NewRegistryValue -typeStr "String" -kind ([Microsoft.Win32.RegistryValueKind]::String) -defaultVal "" })
$MenuNewExpandString.add_Click({ Add-NewRegistryValue -typeStr "ExpandString" -kind ([Microsoft.Win32.RegistryValueKind]::ExpandString) -defaultVal "" })
$MenuNewMultiString.add_Click({ Add-NewRegistryValue -typeStr "MultiString" -kind ([Microsoft.Win32.RegistryValueKind]::MultiString) -defaultVal ([string[]]@()) })
$MenuNewDword.add_Click({ Add-NewRegistryValue -typeStr "DWORD" -kind ([Microsoft.Win32.RegistryValueKind]::DWord) -defaultVal 0 })
$MenuNewQword.add_Click({ Add-NewRegistryValue -typeStr "QWORD" -kind ([Microsoft.Win32.RegistryValueKind]::QWord) -defaultVal 0 })
$MenuNewBinary.add_Click({ Add-NewRegistryValue -typeStr "Binary" -kind ([Microsoft.Win32.RegistryValueKind]::Binary) -defaultVal ([byte[]]@()) })

# Modify Selected Value Handler
function Edit-SelectedValue {
    $selectedVal = $ValuesDataGrid.SelectedItem
    if (-not $selectedVal) { return }
    
    $curPath = $TxtAddressPath.Text
    $vName = $selectedVal.RawName
    $vKind = $selectedVal.TypeKind
    $vRawData = $selectedVal.RawData
    
    $editXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        Title="Edit Value - $($selectedVal.Name)" Height="260" Width="480" WindowStartupLocation="CenterOwner"
        Background="#202020" Foreground="#E1E1E1" ResizeMode="NoResize">
    <Grid Margin="12">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <TextBlock Grid.Row="0" Text="Value name:" Foreground="#999999" Margin="0,0,0,2"/>
        <TextBox Grid.Row="1" Text="$($selectedVal.Name)" IsReadOnly="True" Background="#2A2A2C" Foreground="#999999" Margin="0,0,0,8"/>
        
        <TextBlock Grid.Row="2" Text="Value data:" Foreground="#999999" Margin="0,0,0,2"/>
        <TextBox Grid.Row="3" x:Name="TxtDataInput" AcceptsReturn="True" TextWrapping="Wrap" Background="#252526" Foreground="#E1E1E1" Padding="4" VerticalScrollBarVisibility="Auto"/>
        
        <StackPanel Grid.Row="4" Orientation="Horizontal" HorizontalAlignment="Right" Margin="0,12,0,0">
            <Button x:Name="BtnSave" Content=" OK " Width="80" Margin="4,0" Background="#007ACC" Foreground="White"/>
            <Button x:Name="BtnCancel" Content=" Cancel " Width="80" Margin="4,0" Background="#3E3E42" Foreground="White"/>
        </StackPanel>
    </Grid>
</Window>
"@
    $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($editXaml))
    $dlg = [System.Windows.Markup.XamlReader]::Load($reader)
    $dlg.Owner = $window
    
    $txtData = $dlg.FindName("TxtDataInput")
    $btnSave = $dlg.FindName("BtnSave")
    $btnCancel = $dlg.FindName("BtnCancel")
    
    # Pre-populate current data
    if ($vKind -eq "MultiString" -and $vRawData -is [array]) {
        $txtData.Text = $vRawData -join "`r`n"
    } else {
        $txtData.Text = if ($null -ne $vRawData) { $vRawData.ToString() } else { "" }
    }
    
    $btnSave.add_Click({
        $newDataStr = $txtData.Text
        $regKey = Get-RegKeyObject -fullPath $curPath -writable $true
        if ($regKey) {
            try {
                if ($vKind -eq "DWord") {
                    $parsedNum = [uint32]$newDataStr
                    $regKey.SetValue($vName, $parsedNum, $vKind)
                } elseif ($vKind -eq "QWord") {
                    $parsedNum = [uint64]$newDataStr
                    $regKey.SetValue($vName, $parsedNum, $vKind)
                } elseif ($vKind -eq "MultiString") {
                    $lines = $newDataStr -split "`r?\n"
                    $regKey.SetValue($vName, $lines, $vKind)
                } else {
                    $regKey.SetValue($vName, $newDataStr, $vKind)
                }
                $TxtStatus.Text = "Updated value '$vName'"
                $dlg.DialogResult = $true
                $dlg.Close()
                Get-KeyValues -path $curPath
            } catch {
                [System.Windows.MessageBox]::Show("Error updating value: $_", "Invalid Input", 'OK', 'Error')
            } finally {
                if ($regKey -ne [Microsoft.Win32.Registry]::CurrentUser -and 
                    $regKey -ne [Microsoft.Win32.Registry]::LocalMachine) { $regKey.Close() }
            }
        }
    })
    
    $btnCancel.add_Click({ $dlg.Close() })
    $dlg.ShowDialog() | Out-Null
}

$CtxModify.add_Click({ Edit-SelectedValue })
$ValuesDataGrid.add_MouseDoubleClick({ Edit-SelectedValue })

# Delete Key / Value Handler
$MenuDelete.add_Click({
    $curPath = $TxtAddressPath.Text
    $selectedVal = $ValuesDataGrid.SelectedItem
    
    if ($selectedVal) {
        # Delete Value
        $res = [System.Windows.MessageBox]::Show("Are you sure you want to delete value '$($selectedVal.Name)'?", "Confirm Delete", 'YesNo', 'Warning')
        if ($res -eq 'Yes') {
            $regKey = Get-RegKeyObject -fullPath $curPath -writable $true
            if ($regKey) {
                try {
                    $regKey.DeleteValue($selectedVal.RawName, $false)
                    $TxtStatus.Text = "Deleted value '$($selectedVal.Name)'"
                    Get-KeyValues -path $curPath
                } catch {
                    [System.Windows.MessageBox]::Show("Error deleting value: $_", "Error", 'OK', 'Error')
                } finally {
                    if ($regKey -ne [Microsoft.Win32.Registry]::CurrentUser -and 
                        $regKey -ne [Microsoft.Win32.Registry]::LocalMachine) { $regKey.Close() }
                }
            }
        }
    } else {
        # Delete Key
        if ([string]::IsNullOrEmpty($curPath) -or $curPath -eq "Computer" -or $curPath -match "^Computer\\HKEY_[A-Z_]+$") {
            [System.Windows.MessageBox]::Show("Cannot delete root hives.", "PSRegEdit", 'OK', 'Stop')
            return
        }
        $res = [System.Windows.MessageBox]::Show("Are you sure you want to delete key '$curPath' and ALL subkeys?", "Confirm Delete Key", 'YesNo', 'Warning')
        if ($res -eq 'Yes') {
            $lastSlash = $curPath.LastIndexOf('\')
            $parentPath = $curPath.Substring(0, $lastSlash)
            $subKeyName = $curPath.Substring($lastSlash + 1)
            
            $parentRegKey = Get-RegKeyObject -fullPath $parentPath -writable $true
            if ($parentRegKey) {
                try {
                    $parentRegKey.DeleteSubKeyTree($subKeyName)
                    $TxtStatus.Text = "Deleted key '$subKeyName'"
                    Invoke-NavigateToPath -targetPath $parentPath
                    $BtnRefresh.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Button]::ClickEvent)))
                } catch {
                    [System.Windows.MessageBox]::Show("Error deleting key tree: $_", "Error", 'OK', 'Error')
                } finally {
                    if ($parentRegKey -ne [Microsoft.Win32.Registry]::CurrentUser -and 
                        $parentRegKey -ne [Microsoft.Win32.Registry]::LocalMachine) { $parentRegKey.Close() }
                }
            }
        }
    }
})
$CtxDeleteValue.add_Click({ $MenuDelete.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.MenuItem]::ClickEvent))) })

# Favorites Management
function Get-FavoritesMenu {
    # Remove custom dynamic menu items
    for ($i = $MenuFavoritesRoot.Items.Count - 1; $i -ge 2; $i--) {
        $MenuFavoritesRoot.Items.RemoveAt($i)
    }
    
    if (Test-Path $favoritesPath) {
        try {
            $favs = Get-Content $favoritesPath -Raw | ConvertFrom-Json
            foreach ($f in $favs) {
                $item = New-Object System.Windows.Controls.MenuItem
                $item.Header = "[Fav] " + $f.Name
                $item.ToolTip = $f.Path
                $target = $f.Path
                $item.add_Click({
                    Invoke-NavigateToPath -targetPath $target
                })
                [void]$MenuFavoritesRoot.Items.Add($item)
            }
        } catch {}
    }
}

$BtnAddFav.add_Click({
    $curPath = $TxtAddressPath.Text
    if ([string]::IsNullOrEmpty($curPath) -or $curPath -eq "Computer") { return }
    
    $favName = Show-InputDialog -title "Add Favorite" -prompt "Enter favorite display name:" -defaultValue ($curPath.Split('\')[-1])
    if ([string]::IsNullOrWhiteSpace($favName)) { return }
    
    $favs = @()
    if (Test-Path $favoritesPath) {
        try { $favs = Get-Content $favoritesPath -Raw | ConvertFrom-Json } catch {}
    }
    $favs += @{ Name = $favName; Path = $curPath }
    $favs | ConvertTo-Json | Set-Content $favoritesPath -Force
    Get-FavoritesMenu
    $TxtStatus.Text = "Added '$favName' to Favorites!"
})
$MenuAddFavorite.add_Click({ $BtnAddFav.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Button]::ClickEvent))) })

# Toggle Advanced Search Drawer
$BtnSearch.add_Click({
    if ($SearchDrawer.Visibility -eq 'Collapsed') {
        $SearchDrawer.Visibility = 'Visible'
        $TxtSearchQuery.Focus() | Out-Null
    } else {
        $SearchDrawer.Visibility = 'Collapsed'
    }
})
$MenuToggleSearch.add_Click({ $BtnSearch.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Button]::ClickEvent))) })
$BtnCloseSearch.add_Click({ $SearchDrawer.Visibility = 'Collapsed' })

# Multi-Threaded Asynchronous Search Implementation
$BtnRunSearch.add_Click({
    $query = $TxtSearchQuery.Text.Trim()
    if ([string]::IsNullOrEmpty($query)) {
        [System.Windows.MessageBox]::Show("Please enter a search string.", "Search", 'OK', 'Information')
        return
    }
    
    $SearchResultsGrid.ItemsSource = $null
    $resultsList = [System.Collections.Generic.List[PSObject]]::new()
    $TxtSearchProgress.Text = "Searching..."
    $BtnRunSearch.IsEnabled = $false
    $BtnStopSearch.IsEnabled = $true
    
    $startPath = if ($ChkSearchCurrentKeyOnly.IsChecked) { $TxtAddressPath.Text } else { "Computer" }
    $searchKeys = $ChkSearchKeys.IsChecked
    $searchVals = $ChkSearchValues.IsChecked
    $searchData = $ChkSearchData.IsChecked
    $useRegex = $ChkSearchRegex.IsChecked
    
    # Run Background Worker Thread for fast search
    $worker = [System.ComponentModel.BackgroundWorker]::new()
    $worker.WorkerReportsProgress = $true
    $worker.WorkerSupportsCancellation = $true
    
    $worker.add_DoWork({
        param($wSender, $wEvent)
        
        function Search-RecursiveKey {
            param([string]$keyPath)
            
            if ($worker.CancellationPending) { return }
            
            $regKey = Get-RegKeyObject -fullPath $keyPath -writable $false
            if (-not $regKey) { return }
            
            try {
                # Check Key Name match
                if ($searchKeys) {
                    $keyName = $keyPath.Split('\')[-1]
                    $isMatch = if ($useRegex) { $keyName -match $query } else { $keyName -like "*$query*" }
                    if ($isMatch) {
                        $worker.ReportProgress(0, [PSCustomObject]@{
                            KeyPath     = $keyPath
                            MatchType   = "Key"
                            Name        = "-"
                            DataDisplay = "-"
                        })
                    }
                }
                
                # Check Values match
                if ($searchVals -or $searchData) {
                    $vNames = $regKey.GetValueNames()
                    foreach ($v in $vNames) {
                        if ($worker.CancellationPending) { return }
                        $vData = $regKey.GetValue($v, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                        
                        $matchName = $false
                        $matchValData = $false
                        
                        if ($searchVals -and $v) {
                            $matchName = if ($useRegex) { $v -match $query } else { $v -like "*$query*" }
                        }
                        
                        if ($searchData -and $null -ne $vData) {
                            $strVal = $vData.ToString()
                            $matchValData = if ($useRegex) { $strVal -match $query } else { $strVal -like "*$query*" }
                        }
                        
                        if ($matchName -or $matchValData) {
                            $worker.ReportProgress(0, [PSCustomObject]@{
                                KeyPath     = $keyPath
                                MatchType   = if ($matchName) { "Value Name" } else { "Value Data" }
                                Name        = if ($v) { $v } else { "(Default)" }
                                DataDisplay = if ($null -ne $vData) { $vData.ToString() } else { "" }
                            })
                        }
                    }
                }
                
                # Recurse Subkeys
                $subNames = $regKey.GetSubKeyNames()
                foreach ($sub in $subNames) {
                    if ($worker.CancellationPending) { return }
                    Search-RecursiveKey -keyPath ($keyPath + "\" + $sub)
                }
            } catch {
                # Ignore access denied subkeys during background search
            } finally {
                if ($regKey -ne [Microsoft.Win32.Registry]::CurrentUser -and 
                    $regKey -ne [Microsoft.Win32.Registry]::LocalMachine -and 
                    $regKey -ne [Microsoft.Win32.Registry]::ClassesRoot -and 
                    $regKey -ne [Microsoft.Win32.Registry]::Users -and 
                    $regKey -ne [Microsoft.Win32.Registry]::CurrentConfig) { $regKey.Close() }
            }
        }
        
        if ($startPath -eq "Computer") {
            foreach ($h in $RootHives) {
                Search-RecursiveKey -keyPath ("Computer\" + $h.Name)
            }
        } else {
            Search-RecursiveKey -keyPath $startPath
        }
    })
    
    $worker.add_ProgressChanged({
        param($wSender, $wProgress)
        $item = $wProgress.UserState
        $resultsList.Add($item)
        $SearchResultsGrid.ItemsSource = $null
        $SearchResultsGrid.ItemsSource = $resultsList
        $TxtStatus.Text = "Found $($resultsList.Count) search matches..."
    })
    
    $worker.add_RunWorkerCompleted({
        param($wSender, $wComp)
        $BtnRunSearch.IsEnabled = $true
        $BtnStopSearch.IsEnabled = $false
        $TxtSearchProgress.Text = "Search Complete. Total results: $($resultsList.Count)"
    })
    
    $BtnStopSearch.add_Click({
        $worker.CancelAsync()
        $TxtSearchProgress.Text = "Search Stopping..."
    })
    
    $worker.RunWorkerAsync()
})

# Double Click Search Result Jumps To Key
$SearchResultsGrid.add_MouseDoubleClick({
    $selectedResult = $SearchResultsGrid.SelectedItem
    if ($selectedResult -and $selectedResult.KeyPath) {
        Invoke-NavigateToPath -targetPath $selectedResult.KeyPath
        $TxtStatus.Text = "Jumped to search match in $($selectedResult.KeyPath)"
    }
})

# Export Key (.reg format)
$BtnExport.add_Click({
    $curPath = $TxtAddressPath.Text
    if ([string]::IsNullOrEmpty($curPath) -or $curPath -eq "Computer") {
        [System.Windows.MessageBox]::Show("Select a registry key to export.", "Export", 'OK', 'Information')
        return
    }
    
    $saveDlg = New-Object System.Windows.Forms.SaveFileDialog
    $saveDlg.Filter = "Registry Files (*.reg)|*.reg|All Files (*.*)|*.*"
    $saveDlg.Title = "Export Registry Key"
    $saveDlg.FileName = ($curPath.Split('\')[-1]) + ".reg"
    
    if ($saveDlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $regExportPath = $curPath -replace "^Computer\\", ""
        $proc = Start-Process -FilePath "reg.exe" -ArgumentList "export `"$regExportPath`" `"$($saveDlg.FileName)`" /y" -NoNewWindow -Wait -PassThru
        if ($proc.ExitCode -eq 0) {
            $TxtStatus.Text = "Successfully exported to $($saveDlg.FileName)"
            [System.Windows.MessageBox]::Show("Registry key exported successfully!", "Export", 'OK', 'Information')
        } else {
            [System.Windows.MessageBox]::Show("Export failed with exit code $($proc.ExitCode)", "Export Error", 'OK', 'Error')
        }
    }
})
$MenuExport.add_Click({ $BtnExport.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Button]::ClickEvent))) })

# Import Registry File (.reg format)
$BtnImport.add_Click({
    $openDlg = New-Object System.Windows.Forms.OpenFileDialog
    $openDlg.Filter = "Registry Files (*.reg)|*.reg|All Files (*.*)|*.*"
    $openDlg.Title = "Import Registry File"
    
    if ($openDlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $proc = Start-Process -FilePath "reg.exe" -ArgumentList "import `"$($openDlg.FileName)`"" -NoNewWindow -Wait -PassThru
        if ($proc.ExitCode -eq 0) {
            $TxtStatus.Text = "Successfully imported $($openDlg.FileName)"
            [System.Windows.MessageBox]::Show("Registry file imported successfully!", "Import", 'OK', 'Information')
            $BtnRefresh.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Button]::ClickEvent)))
        } else {
            [System.Windows.MessageBox]::Show("Import failed. Ensure PSRegEdit is running as Administrator.", "Import Error", 'OK', 'Error')
        }
    }
})
$MenuImport.add_Click({ $BtnImport.RaiseEvent((New-Object System.Windows.RoutedEventArgs([System.Windows.Controls.Button]::ClickEvent))) })

# Permissions Viewer
$MenuPermissions.add_Click({
    $curPath = $TxtAddressPath.Text
    if ([string]::IsNullOrEmpty($curPath) -or $curPath -eq "Computer") { return }
    
    try {
        $parsed = Split-RegistryPath -path $curPath
        $psProviderPath = "HKLM:\"
        switch ($parsed.HiveName) {
            "HKEY_CURRENT_USER"  { $psProviderPath = "HKCU:\" + $parsed.SubKey }
            "HKCU"               { $psProviderPath = "HKCU:\" + $parsed.SubKey }
            "HKEY_LOCAL_MACHINE" { $psProviderPath = "HKLM:\" + $parsed.SubKey }
            "HKLM"               { $psProviderPath = "HKLM:\" + $parsed.SubKey }
            "HKEY_CLASSES_ROOT"  { $psProviderPath = "HKCR:\" + $parsed.SubKey }
            "HKCR"               { $psProviderPath = "HKCR:\" + $parsed.SubKey }
            "HKEY_USERS"         { $psProviderPath = "Registry::HKEY_USERS\" + $parsed.SubKey }
        }
        
        $acl = Get-Acl -Path $psProviderPath
        $owner = $acl.Owner
        $accessRules = $acl.Access | Select-Object IdentityReference, AccessControlType, RegistryRights, IsInherited
        
        $aclXaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        Title="Key Security &amp; Permissions - $curPath" Height="400" Width="600" WindowStartupLocation="CenterOwner"
        Background="#202020" Foreground="#E1E1E1">
    <Grid Margin="12">
        <Grid.RowDefinitions>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="Auto"/>
            <RowDefinition Height="*"/>
            <RowDefinition Height="Auto"/>
        </Grid.RowDefinitions>
        <TextBlock Grid.Row="0" Text="Owner: $owner" Foreground="#007ACC" FontWeight="Bold" FontSize="14" Margin="0,0,0,8"/>
        <TextBlock Grid.Row="1" Text="Access Control List (ACL):" Foreground="#999999" Margin="0,0,0,4"/>
        <DataGrid Grid.Row="2" x:Name="AclGrid" AutoGenerateColumns="True" IsReadOnly="True" Background="#1E1E1E"/>
        <Button Grid.Row="3" x:Name="BtnCloseAcl" Content=" Close " Width="90" HorizontalAlignment="Right" Margin="0,8,0,0" Background="#3E3E42" Foreground="White"/>
    </Grid>
</Window>
"@
        $reader = [System.Xml.XmlReader]::Create([System.IO.StringReader]::new($aclXaml))
        $aclDlg = [System.Windows.Markup.XamlReader]::Load($reader)
        $aclDlg.Owner = $window
        
        $grid = $aclDlg.FindName("AclGrid")
        $grid.ItemsSource = $accessRules
        $btnClose = $aclDlg.FindName("BtnCloseAcl")
        $btnClose.add_Click({ $aclDlg.Close() })
        
        $aclDlg.ShowDialog() | Out-Null
    } catch {
        [System.Windows.MessageBox]::Show("Error retrieving ACL permissions: $_", "Security Viewer Error", 'OK', 'Error')
    }
})

# Menu Exit & About
$MenuExit.add_Click({ $window.Close() })
$MenuAbout.add_Click({
    $aboutText = "PSRegEdit v1.0`n" +
                 "Modern Registry Editor for PowerShell`n`n" +
                 "Features:`n" +
                 "- Native Dark WPF Interface`n" +
                 "- Fast Virtualized Registry Tree (HKLM, HKCU, HKCR, HKU, HKCC)`n" +
                 "- Multi-Threaded Recursive Search & Jump`n" +
                 "- Breadcrumb Address Bar`n" +
                 "- Value Filtering & Hex Viewer`n" +
                 "- Favorites Bookmark Manager`n" +
                 "- Native .reg Import & Export`n" +
                 "- ACL / Security Permissions Viewer"
    [System.Windows.MessageBox]::Show($aboutText, "About PSRegEdit", 'OK', 'Information')
})

# Initialize Favorites Menu & Root Tree
Get-FavoritesMenu
Initialize-Tree

# Show Application Window
$window.ShowDialog() | Out-Null
