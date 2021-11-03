<#
    .NOTES
        Author: Mark McGill, VMware
        Last Edit: 11-3-2021
        Version 1.0
    .SYNOPSIS
        Queries a Horizon UAG's REST API for statistics, and returns them in an object that can be written to a csv (1 liner)
    .DESCRIPTION
        Converts the XML response from the UAG to a hashtable, then recurses through all values. The value is written to a PSObject 
        when it is detected as a string. Names of the parent values are appended to the string value
    .EXAMPLE
        Get-UAG_Stats -uag "uagName.domain.com" -credentials $credentialObj | Export-Csv "c:\temp\uag-log.csv" -NoTypeInformation
    .OUTPUTS
        PSObject
#>
Function Get-UAG_Stats
{
    #Requires -Version 6.0
    [cmdletbinding()]
    Param
    (
        [Parameter(Mandatory=$true)]$uag,
        [Parameter(Mandatory=$false)]$credentials
    )
    #credit to Phil Factor for the ConvertFrom-XML function (https://www.red-gate.com/simple-talk/blogs/convert-from-xml/)
    function ConvertFrom-XML
    {
        [CmdletBinding()]
        param
        (
            [Parameter(Mandatory = $true, ValueFromPipeline)]
            [System.Xml.XmlNode]$node, #we are working through the nodes
            [string]$Prefix='',#do we indicate an attribute with a prefix?
            $ShowDocElement=$false #Do we show the document element? 
        )
        process
        {   #if option set, we skip the Document element
            if ($node.DocumentElement -and !($ShowDocElement)) 
                { $node = $node.DocumentElement }
            $oHash = [ordered] @{ } # start with an ordered hashtable.
            #The order of elements is always significant regardless of what they are
            write-verbose "calling with $($node.LocalName)"
            if ($node.Attributes -ne $null) #if there are elements
            # record all the attributes first in the ordered hash
            {
                $node.Attributes | foreach {
                    $oHash.$($Prefix+$_.FirstChild.parentNode.LocalName) = $_.FirstChild.value
                }
            }
            # check to see if there is a pseudo-array. (more than one
            # child-node with the same name that must be handled as an array)
            $node.ChildNodes | #we just group the names and create an empty
            #array for each
            Group-Object -Property LocalName | where { $_.count -gt 1 } | select Name |
            foreach{
                write-verbose "pseudo-Array $($_.Name)"
                $oHash.($_.Name) = @() <# create an empty array for each one#>
            };
            foreach ($child in $node.ChildNodes)
            {#now we look at each node in turn.
                write-verbose "processing the '$($child.LocalName)'"
                $childName = $child.LocalName
                if ($child -is [system.xml.xmltext])
                # if it is simple XML text 
                {
                    write-verbose "simple xml $childname";
                    $oHash.$childname += $child.InnerText
                }
                # if it has a #text child we may need to cope with attributes
                elseif ($child.FirstChild.Name -eq '#text' -and $child.ChildNodes.Count -eq 1)
                {
                    write-verbose "text";
                    if ($child.Attributes -ne $null) #hah, an attribute
                    {
                        <#we need to record the text with the #text label and preserve all
                        the attributes #>
                        $aHash = [ordered]@{ };
                        $child.Attributes | foreach {
                            $aHash.$($_.FirstChild.parentNode.LocalName) = $_.FirstChild.value
                        }
                        #now we add the text with an explicit name
                        $aHash.'#text' += $child.'#text'
                        $oHash.$childname += $aHash
                    }
                    else
                    { #phew, just a simple text attribute. 
                        $oHash.$childname += $child.FirstChild.InnerText
                    }
                }
                elseif ($child.'#cdata-section' -ne $null)
                # if it is a data section, a block of text that isnt parsed by the parser,
                # but is otherwise recognized as markup
                {
                    write-verbose "cdata section";
                    $oHash.$childname = $child.'#cdata-section'
                }
                elseif ($child.ChildNodes.Count -gt 1 -and 
                            ($child | gm -MemberType Property).Count -eq 1)
                {
                    $oHash.$childname = @()
                    foreach ($grandchild in $child.ChildNodes)
                    {
                        $oHash.$childname += (ConvertFrom-XML $grandchild)
                    }
                }
                else
                {
                    # create an array as a value  to the hashtable element
                    $oHash.$childname += (ConvertFrom-XML $child)
                }
            }
            $oHash
        }
    } 

    Function Recurse-ObjectMembers($hashtable,$parents,$resultsObj)
    {
        
        foreach($key in $hashtable.keys)
        {
            
            #Write-Host $member.Name -ForegroundColor Yellow
            $memberName = $key
            $memberValue = $hashtable.$key
            $memberType = $hashtable.$key.GetType().Name

            If ($parents -ne $null)
            {
                $parent = ($parents + "." + $memberName).Trim(".")
            }
            Else
            {
                $parent = $memberName
            }

            Switch ($memberType)
            {
                "string" 
                {
                    $name = $parent
                    $value = $hashtable.($memberName)
                    $resultsObj | Add-Member -NotePropertyName $name -NotePropertyValue $value
                    #Write-Host "$name - $value"
                    #Write-Host "-------------------------"

                }
                "OrderedDictionary" 
                {
                    #$parent = ($parent + "." + $memberName).Trim(".")
                    Recurse-ObjectMembers $memberValue $parent $resultsObj | Out-Null
                }
                "Object[]" 
                {
                    foreach ($arrMember in $memberValue)
                    {
                        foreach ($member in $arrMember)
                        {
                            $parent = ($parent + "." + $member.Name).Trim(".")
                            Recurse-ObjectMembers $member $parent $resultsObj | Out-Null
                            $parent = (($parent.Split($member.Name))[0]).Trim(".")
                        }
                    }
                }
            }
                
        }
        Return $resultsObj
    }

    #main code body
    $monitorUri = "https://$uag" + ":9443/rest/v1/monitor/stats"
    $contentType = "application/xml"
    $response = Invoke-Restmethod -Uri $monitorUri -Method Get -Credential $credentials -ContentType $contentType -SkipCertificateCheck
    $xml = $response.accessPointStatusAndStats
    $hashtable = ConvertFrom-XML $xml
    $resultsObj = New-Object PSObject -Property @{}
    $stats = Recurse-ObjectMembers $hashtable $null $resultsObj
    Return $stats
}
