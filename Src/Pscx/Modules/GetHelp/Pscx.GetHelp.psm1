#requires -Version 3

param([string[]]$PreCacheList)

if (!(Test-Path variable:\helpCache) -or $RefreshCache) {
    $SCRIPT:helpCache = @{}
}

function Resolve-MemberOwnerType
{
    [CmdletBinding()]
    param
    (
        [system.management.automation.psmethod]$method
    )

    # TODO: support overloads, support interface definitions

    $PSCmdlet.WriteVerbose("Resolving $($method.name)'s owning Type.")

    # hackety-hack - this is prone to breaking in the future
    $targetType = [system.management.automation.psmethod].getfield("baseObject", "Instance,NonPublic").getvalue($method)

    # [system.runtimetype] is special-cased in powershell - you can't reference it?
    if (-not ($targetType.GetType().fullname -eq "System.RuntimeType"))
    {
        $targetType = $targetType.GetType()
    }

    if ($method.OverloadDefinitions -match "static")
    {
        $flags = "Static,Public"
    }
    else
    {
        $flags = "Instance,Public"
    }

    # FIXME: support overloads
    $methodInfo = $targetType.GetMethods($flags) | ?{$_.Name -eq $method.Name}| select -first 1

    if (-not $methodInfo)
    {
        # this shouldn't happen.
        throw "Could not resolve owning type!"
    }

    $declaringType = $methodInfo.DeclaringType

    $PSCmdlet.WriteVerbose("Owning Type is $($targetType.fullname). Method declared on $($declaringType.fullname).")

    $declaringType
}

function Get-DocsLocation
{
    [CmdletBinding()]
    param
    (
        [type]$type,

        [switch]$Online,

        [switch]$Members,

        [switch]$Static
    )

    # get documentation filename, assembly location and assembly codebase
    $docFilename = [io.path]::changeextension([io.path]::getfilename($type.assembly.location), ".xml")
    $location = [io.path]::getdirectoryname($type.assembly.location)
    $codebase = (new-object uri $type.assembly.codebase).localpath

    $PSCmdlet.WriteVerbose("Documentation file is $docFilename")

    if (-not $Online.IsPresent)
    {
        # try localized location (typically newer than base framework dir)
        $frameworkDir = "${env:windir}\Microsoft.NET\framework\v2.0.50727"
        $lang = [system.globalization.cultureinfo]::CurrentUICulture.parent.name

        # I love looking at this. A Duff's Device for PowerShell.. well, maybe not.
        switch
            (
            "${frameworkdir}\${lang}\$docFilename",
            "${frameworkdir}\$docFilename",
            "$location\$docFilename",
            "$codebase\$docFilename"
            )
        {
            { test-path $_ } { $_; return; }

            default
            {
                # try next path
                continue;
            }
        }
    }

    # failed to find local docs, is it from MS?
    if ((Get-ObjectVendor $type) -like "*Microsoft*")
    {
        # drop locale - site will redirect to correct variation based on browser accept-lang
        $suffix = ""
        if ($Members.IsPresent)
        {
            $suffix = "_members"
        }

        new-object uri ("http://msdn.microsoft.com/library/{0}{1}.aspx" -f $type.fullname,$suffix)

        return
    }

    $PSCmdlet.WriteWarning("Sorry, I couldn't find any local documentation for ${type}.")
}

# Dig out something that might lead us to the vendor of this Object
function Get-ObjectVendor
{
    [CmdletBinding()]
    param
    (
        [type]$type,
        [switch]$CompanyOnly
    )

    $assembly = $type.assembly
    $attrib = $assembly.GetCustomAttributes([Reflection.AssemblyCompanyAttribute], $false) | select -first 1

    if ($attrib.Company)
    {
        # try company
        $attrib.Company
        return
    }
    else
    {
        if ($CompanyOnly) { return }

        # try copyright
        $attrib = $assembly.GetCustomAttributes([Reflection.AssemblyCopyrightAttribute], $false) | select -first 1

        if ($attrib.Copyright)
        {
            $attrib.Copyright
            return
        }
    }
    $PSCmdlet.WriteVerbose("Assembly has no [AssemblyCompany] or [AssemblyCopyright] attributes.")
}

function Get-HelpSummary
{
        [CmdletBinding()]
        param
        (
            [string]$file,
            [reflection.assembly]$assembly,
            [string]$selector
        )

        if ($helpCache.ContainsKey($assembly))
        {
            $xml = $helpCache[$assembly]

            $PSCmdlet.WriteVerbose("Docs were found in the cache.")
        }
        else
        {
            # cache it
            Write-Progress -id 1 "Caching Help Documentation" $assembly.getname().name

            # cache this for future lookups. It's a giant pig. Oink.
            $xml = [xml](gc $file)

            $helpCache.Add($assembly, $xml)

            Write-Progress -id 1 "Caching Help Documentation" $assembly.getname().name -completed
        }

        $PSCmdlet.WriteVerbose("Selector is $selector")

        # TODO: support overloads
        $summary = $xml.doc.members.SelectSingleNode("member[@name='$selector' or starts-with(@name,'$selector(')]").summary

        $summary
}

function Show-Help
{
@"


SYNTAX

$((get-help get-objecthelp).split([char]13) | % { "$_" })
"@
}

function Get-ObjectHelp
{
    [CmdletBinding()]
    param
    (
        [Parameter(ValueFromPipeline=$true, Mandatory=$true)]
        [ValidateNotNull()]
        $Object,

        [Parameter()]
        [switch]$Online,

        [Parameter()]
        [switch]$Member,

        [Parameter()]
        [switch]$Static
    )

    process
    {
        if ($Object -is [string])
        {
            $PSCmdlet.WriteVerbose("A string was passed - reparsing as expression.")

            # they probably meant to pass the string inside '(' and ').'
            try
            {
                # e.g. "[int]::gettype" was passed without being wrapped
                # in new evaluative parentheses.
                $Object = invoke-expression $Object
            }
            catch
            {
                if ($_.fullyqualifiederrorid -eq "TypeNotFound,Microsoft.PowerShell.Commands.InvokeExpressionCommand")
                {
                    $PSCmdlet.WriteWarning("I don't recognize the Type in ${InputObject}. Are you sure you've typed it correctly?")
                }
                else
                {
                    $PSCmdlet.WriteWarning("A string was passed and was parsed as an expression, and failed. " +
                        "If you really meant to find help on strings, pass [string] instead.")
                }
                $PSCmdlet.WriteVerbose($_)

                return
            }
        }

        $type = $Object.GetType()
        $PSCmdlet.WriteVerbose("InputObject Type is $($type.Fullname)")

        $selector = $null

        # won't work with $type; case statements don't match with type literals?
        switch ($type.FullName)
        {
            "System.RuntimeType"
            {
                $PSCmdlet.WriteVerbose("[runtimetype]")

                $type = $Object
                $selector = "T:$($type.FullName)"

                break;
            }

            "System.Management.Automation.PSMethod"
            {
                $PSCmdlet.WriteVerbose("[psmethod]")

                $type = Resolve-MemberOwnerType $Object

                # TODO: support overloaded methods
                $selector = "M:$($type.FullName).$($Object.Name)"

                break;
            }

            default
            {
                $PSCmdlet.WriteVerbose("[object]")
                $selector = "T:$($type.FullName)"
            }
        }

        # do we have an assembly help xml somewhere?
        $docs = Get-DocsLocation $type -Online:$Online.IsPresent -Members:$Member.IsPresent -Static:$Static.IsPresent

        if ($docs)
        {
            $PSCmdlet.WriteVerbose("Found $docs")

            if ($docs -is [uri])
            {
                # Could not find local xml, but object is from Microsoft. Offer to view MSDN.
                $title = "Microsoft Developer Network"
                $message = "No local help for $($type.fullname).`n`nDo you want to visit this object's documentation page on MSDN?"
                $options = [System.Management.Automation.Host.ChoiceDescription[]]("&Yes", "&No")

                $result = $host.ui.PromptForChoice($title, $message, $options, 0)

                if ($result -eq 0) {
                    Start-Process $docs -Verb Open > $null
                }
                return
            }

            # get summary, if possible
            $summary = Get-HelpSummary $docs $type.assembly $selector

            if ($summary)
            {
                [string]::empty

                # TODO: parse out <see ...> tags and create a PromptForChoice list to lookup referenced type(s).
                if ($summary.selectnodes) {
                    $see = $summary.selectnodes("see")
                }

                if (($Object -eq 42) -and (!$PSCmdlet.Force)) {

                    "What do you get if you multiply six by nine?"
                    [string]::empty
                    "That's it. That's all there is."

                } else {

                    $text = & {
                        if ($summary.innerxml) {
                            $summary.innerxml.trim()
                        }
                        else
                        {
                            $summary.trim()
                        }
                    }

                    # strip <see ... /> tags
                    $text -replace [regex]'<see.*?"?:(.*?)"\s/>', '$1'
                }

                if ((Test-Path Variable:\see) -and $see) {
                    #Show-References
                    # TODO: list of <see cref="foo" /> types
                }

                [string]::empty
            }
            else
            {
                Write-Host "While some local documentation was found, it was incomplete. Sorry!"
            }
        }
        else
        {
            Write-Host "Sorry, I couldn't find any local documentation for ${type}."

            $vendor = Get-ObjectVendor $type -CompanyOnly

            if ($vendor)
            {
                # needed for urlencode
                add-type -a system.web

                write-host "However, it looks like the vendor of this Object is '${vendor}.'"

                $title = "Bing Search"
                $message = "Do you want to search for this object's documentation?"
                $options = [System.Management.Automation.Host.ChoiceDescription[]]("&Yes", "&No")

                $result = $host.ui.PromptForChoice($title, $message, $options, 0)

                if ($result -eq 0) {
                    # encode our question
                    $q = [system.web.httputility]::urlencode(("`"{0}`" {1}" -f $vendor, $type))

                    # fire up the browser
                    [diagnostics.process]::Start("http://www.bing.com/results.aspx?q=$q")
                }
            }
        }
    }
}

# cache common assembly help
function Preload-Documentation
{
    if ($SCRIPT:helpCache.Keys.Count -eq 0) {
        # mscorlib
        $file = Get-DocsLocation ([int])
        Get-HelpSummary $file ([int].assembly) "T:System.Int32" > $null

        # system
        $file = Get-DocsLocation ([regex])
        Get-HelpSummary $file ([regex].assembly) "T:System.Regex" > $null
    }
}

<#
.ForwardHelpTargetName Get-Help
.ForwardHelpCategory Cmdlet
#>
function Get-PscxHelp {
    # our proxy command generated from [proxycommand]::create((gcm get-help))
    [CmdletBinding(DefaultParameterSetName='AllUsersView', HelpUri='http://go.microsoft.com/fwlink/?LinkID=113316')]
    param(
        [Parameter(Position=0, ValueFromPipelineByPropertyName=$true)]
        [System.String]
        ${Name},

        [System.String]
        ${Path},

        [System.String[]]
        ${Category},

        [System.String[]]
        ${Component},

        [System.String[]]
        ${Functionality},

        [System.String[]]
        ${Role},

        [Parameter(ParameterSetName='DetailedView', Mandatory=$true)]
        [Switch]
        ${Detailed},

        [Parameter(ParameterSetName='AllUsersView')]
        [Switch]
        ${Full},

        [Parameter(ParameterSetName='Examples', Mandatory=$true)]
        [Switch]
        ${Examples},

        [Parameter(ParameterSetName='Parameters', Mandatory=$true)]
        [System.String]
        ${Parameter},

        [Parameter(ParameterSetName='ObjectHelp', ValueFromPipeline = $true, Mandatory = $true)]
        [ValidateNotNullOrEmpty()]
        ${Object},

        [Parameter(ParameterSetName='ObjectHelp')]
        [Switch]
        ${Member},

        [Parameter(ParameterSetName='ObjectHelp')]
        [Switch]
        ${Static},

        [Parameter(ParameterSetName='ObjectHelp')]
        [Parameter(ParameterSetName='Online', Mandatory=$true)]
        [switch]
        ${Online},

        [Parameter(ParameterSetName='ShowWindow', Mandatory=$true)]
        [switch]
        ${ShowWindow}
    )

    begin
    {
        try
        {
            if ($PSCmdlet.ParameterSetName -eq "ObjectHelp")
            {
                Preload-Documentation

                $wrappedCmd = $ExecutionContext.InvokeCommand.GetCommand('Get-ObjectHelp', [System.Management.Automation.CommandTypes]::Function)
                $scriptCmd = { & $wrappedCmd @PSBoundParameters }
                $steppablePipeline = $scriptCmd.GetSteppablePipeline($myInvocation.CommandOrigin)
            }
            else
            {
				# Working around a bug in PowerShell (try man -?) where it passes in the wrong category info for aliases.
                if ($Name -ne $null)
                {
				    $commandInfo = try
					{
						Microsoft.PowerShell.Core\Get-Command $Name -ErrorAction SilentlyContinue
					}
					catch
					{
						Write-Warning "Error calling Get-Command on ${Name}: $_"
					}
					if ($commandInfo -ne $null)
					{
						$isAlias = $commandInfo.CommandType -eq 'Alias'
						if ($isAlias)
						{
							$PSBoundParameters['Category'] = 'Alias'
						}
					}
                }

                $outBuffer = $null
                if ($PSBoundParameters.TryGetValue('OutBuffer', [ref]$outBuffer) -and $outBuffer -gt 1024)
                {
                    $PSBoundParameters['OutBuffer'] = 1024
                }

                $wrappedCmd = $ExecutionContext.InvokeCommand.GetCommand('Microsoft.PowerShell.Core\Get-Help', [System.Management.Automation.CommandTypes]::Cmdlet)
                $scriptCmd = { & $wrappedCmd @PSBoundParameters }
                $steppablePipeline = $scriptCmd.GetSteppablePipeline($myInvocation.CommandOrigin)
            }
            $steppablePipeline.Begin($PSCmdlet)
        }
        catch {
            throw
        }
    }

    process
    {
        try {
            $steppablePipeline.Process($_)
        } catch {
            throw
        }
    }

    end
    {
        try {
            $steppablePipeline.End()
        } catch {
            throw
        }
    }
}

Export-ModuleMember Get-PscxHelp

<#
    NAME

        ObjectHelp Extensions Module 0.3 for PowerShell 2.0

    SYNOPSIS

         Get-Help -Object allows you to display usage and summary help for .NET Types and Members.

    DETAILED DESCRIPTION

        Get-Help -Object allows you to display usage and summary help for .NET Types and Members.

        If local documentation is not found and the object vendor is Microsoft, you will be directed
        to MSDN online to the correct page. If the vendor is not Microsoft and vendor information
        exists on the owning assembly, you will be prompted to search for information using Bing.

    TODO

         * localize strings into PSD1 file
         * Implement caching in hashtables. XMLDocuments are fat pigs.
         * Support getting property/field help
         * PowerTab integration?
         * Test with Strict Parser

    EXAMPLES

        # get help on a type
        PS> Get-PscxHelp -obj [int]

        # get help against live instances
        PS> $obj = new-object system.xml.xmldocument
        PS> Get-PscxHelp -obj `$obj

        or even:

        PS> Get-PscxHelp -obj 42

        # get help against methods
        PS> Get-PscxHelp -obj `$obj.Load

        # explictly try msdn
        PS> Get-PscxHelp -obj [regex] -online

        # go to msdn for regex's members
        PS> Get-PscxHelp -obj [regex] -online -member

        # pipe support
        PS> 1,[int],[string]::format | Get-PscxHelp -verbose

    CREDITS

        Author: Oisin Grehan (MVP)
        Blog  : http://www.nivot.org/

        Have fun!
#>
