<?xml version="1.0" encoding="utf-8"?>
<!--
 Copyright 2013-2019 Rik Essenius

 Licensed under the Apache License, Version 2.0 (the "License"); you may not use this file except in 
 compliance with the License. You may obtain a copy of the License at

   http://www.apache.org/licenses/LICENSE-2.0

 Unless required by applicable law or agreed to in writing, software distributed under the License is
 distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 See the License for the specific language governing permissions and limitations under the License.
-->
<xsl:stylesheet
  version="1.0"
  xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
  xmlns:msxsl="urn:schemas-microsoft-com:xslt"
  exclude-result-prefixes="msxsl"
>

<!--<xsl:output method="xml" version="1.0" encoding="UTF-8" doctype-public="-//W3C//DTD XHTML 1.1//EN" doctype-system="http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd" indent="yes"/> -->

<xsl:output method="html" doctype-system="about:legacy-compat" encoding="UTF-8" indent="yes" />

  <!-- a bit of a hack. In the REST fixture, we create XML documents on the fly.
       But FitNesse doesn't handle that well when running - not enough escaping
       That makes the content section invalid if unescaped. 
       So we need to replace the xml arrow-question mark pairs with their escaped versions 
       That is done using this replace template -->
  
  <xsl:template name="replace">
    <xsl:param name="text"/>
    <xsl:param name="find"/>
    <xsl:param name="replacewith"/>
    <xsl:choose>
      <xsl:when test="contains($text, $find)">
        <xsl:value-of select="substring-before($text, $find)" disable-output-escaping="no"/>
        <xsl:value-of select="$replacewith"/>
        <xsl:call-template name="replace">
          <xsl:with-param name="text" select="substring-after($text, $find)"/>
          <xsl:with-param name="find" select="$find" />
          <xsl:with-param name="replacewith" select="$replacewith" />
        </xsl:call-template>        
      </xsl:when>
      <xsl:otherwise>
        <xsl:value-of select="$text" disable-output-escaping="no"/>       
      </xsl:otherwise>
    </xsl:choose>
  </xsl:template>
  
  <!-- strip elements from the output stream, allowing nesting. Nesting only works right if the starttag is a simple tag. 
       With more complicated cases (see include_stripped_content below) it assumes that there is no nesting -->
  <xsl:template name="elementstripper">
    <xsl:param name="text"/>
    <xsl:param name="starttag"/>
    <xsl:param name="startprefix"/>
    <xsl:param name="endtag"/>
    <xsl:param name="includeproperty"/>
    <xsl:param name="depth"/>

    <xsl:variable name="firststart" select="concat($startprefix,$starttag)"/>

    <xsl:choose>
      <!-- if we have nesting depth 0, we're looking for a new element to filter out. Leave in everything before -->
      <xsl:when test="$depth=0">
        <xsl:choose>
          <xsl:when test="contains($text, $firststart)">
            <xsl:value-of select="substring-before($text, $firststart)" disable-output-escaping="yes"/>
            <xsl:call-template name="elementstripper">
              <xsl:with-param name="text" select="substring-after($text, $firststart)"/>
              <xsl:with-param name="starttag" select="$starttag"/>
              <xsl:with-param name ="startprefix" select="$startprefix" />
              <xsl:with-param name="endtag" select="$endtag"/>
              <xsl:with-param name ="includeproperty" select="$includeproperty" />
              <xsl:with-param name="depth" select="$depth + 1"/>
            </xsl:call-template>
          </xsl:when>
          <xsl:otherwise>
            <!-- no (more) elements found, pass back the rest -->
            <xsl:value-of select="$text" disable-output-escaping="yes"/>
          </xsl:otherwise>
        </xsl:choose>
      </xsl:when>
      <xsl:otherwise>
        <!-- depth>0>, so we are skipping. Search for end tag -->
        <xsl:choose>
          <!-- if there is a start tag before the next end tag, skip till after the start tag and go a level up -->
          <xsl:when test="contains(substring-before($text,$endtag),$starttag)">
            <xsl:call-template name="elementstripper">
              <xsl:with-param name="text" select="substring-after($text, $starttag)"/>
              <xsl:with-param name ="startprefix" select="$startprefix"/>
              <xsl:with-param name="starttag" select="$starttag"/>
              <xsl:with-param name="endtag" select="$endtag"/>
              <xsl:with-param name ="includeproperty" select="$includeproperty"/>
              <xsl:with-param name="depth" select="$depth + 1"/>
            </xsl:call-template>
          </xsl:when>
          <!-- no start tag before the next end tag, so skip till after the end tag and go one level down 
               if the first property (to be included in starttag) needs to be included instead, do so. 
               We use this to replace the link to an included page by the page itself -->
          <xsl:otherwise>
            <xsl:if test="$includeproperty">
              <xsl:text>[</xsl:text>
              <xsl:value-of select="$startprefix"/>
              <xsl:value-of select="substring-before($text,'&quot;')" disable-output-escaping="yes" />
              <xsl:text>]</xsl:text>
            </xsl:if>
            <xsl:call-template name="elementstripper">
              <xsl:with-param name="text" select="substring-after($text, $endtag)"/>
              <xsl:with-param name ="startprefix" select="$startprefix"/>
              <xsl:with-param name="starttag" select="$starttag"/>
              <xsl:with-param name="endtag" select="$endtag"/>
              <xsl:with-param name ="includeproperty" select="$includeproperty" />
              <xsl:with-param name="depth" select="$depth - 1"/>
            </xsl:call-template>
          </xsl:otherwise>
        </xsl:choose>
      </xsl:otherwise>
    </xsl:choose>
  </xsl:template>

  <xsl:template name="FullPageName">
    <xsl:param name="pageName" />
    <xsl:choose>
      <xsl:when test="pageHistoryLink">
        <xsl:value-of select="substring-after(substring-before(pageHistoryLink,'?'),concat($pageName,'.'))"/>
      </xsl:when>
      <xsl:otherwise>
        <xsl:value-of select="relativePageName"/>
      </xsl:otherwise>
    </xsl:choose>
  </xsl:template>

  <xsl:template name="TestResult">
    <xsl:param name="pageName"/>
    <xsl:param name="right"/>
    <xsl:param name="wrong"/>
    <xsl:param name="exceptions"/>
    <xsl:choose>
      <xsl:when test="$wrong &gt; 0">fail</xsl:when>
      <xsl:when test="$exceptions &gt; 0">error</xsl:when>
      <xsl:when test="$right &gt; 0">pass</xsl:when>
      <xsl:otherwise>
        <xsl:choose>
          <xsl:when test="$pageName='SetUp' or $pageName='TearDown' or $pageName='SuiteSetUp' or $pageName='SuiteTearDown'">pass</xsl:when>
          <xsl:otherwise>ignore</xsl:otherwise>
        </xsl:choose>
      </xsl:otherwise>
    </xsl:choose>
  </xsl:template>

  <!-- Main section starts here. First replace all the links to included pages by the page names themselves. 
     Then remove all the links (which allow collapsing etc.). Finally, if there are unnumbered lists, 
     remove those as well. This is needed in Fitnesse 20121220 which added lists around the collapse buttons.
     The choose construct in the title element is to work around a bug in FitNesse 20121220 -->
  <xsl:template match="testResults">

    <xsl:variable name="title">
      <xsl:choose>
        <xsl:when test="rootPath='$response.RootPath'">
          <xsl:value-of select="result/relativePageName"/>
        </xsl:when>
        <xsl:otherwise>
          <xsl:value-of select="rootPath"/>
        </xsl:otherwise>
      </xsl:choose>
    </xsl:variable>

    <html>
      <head>
        <title>
          <xsl:value-of select="$title"/>
        </title>
        <style type="text/css">
          <xsl:text disable-output-escaping="yes"><![CDATA[
        body { font:normal 80% Verdana, Helvetica, Arial, sans-serif; padding: 0; margin: 0 2em; }
        .pass { background-color: #AAFFAA; }
        .fail { background-color: #FFAAAA; }
        .diff { background-color: #FF6666; }
        .error { background-color: #FFFFAA; }
        .ignore { background-color: #CCCCCC; }
        .right { float:right; font-style: italic; font-weight: lighter; line-height: 1.2em; }
        table, td { font-size: 1em; border-color:black; border-style:solid; }
        table { border-width: 0 0 1px 1px; border-collapse: collapse; border-spacing: 0; }
        td { margin:0; padding: 4px; border-width: 1px 1px 0 0; }
        h1 { font-size: 1.5em; }
        h2 { font-size: 1.2em; padding: 0.3em; }
    ]]></xsl:text>
        </style>
      </head>
      <body>
        <xsl:if test="executionLog/exception">
          <h1>Exception</h1>
          <span class="error"><xsl:value-of select="executionLog/exception"/></span>
        </xsl:if>
        <xsl:if test="count(//result) &gt; 1">
          <h1>
            <xsl:attribute name="class">
              <xsl:call-template name="TestResult">
                <xsl:with-param name="pageName" select = "$title"/>
                <xsl:with-param name="right" select = "finalCounts/right"/>
                <xsl:with-param name="wrong" select = "finalCounts/wrong"/>
                <xsl:with-param name="exceptions" select = "finalCounts/exceptions"/>
              </xsl:call-template>
            </xsl:attribute>
            <xsl:value-of select="$title"/>
          </h1>

          <table>
            <tr>
              <td>Page</td>
              <td>Right</td>
              <td>Wrong</td>
              <td>Ignores</td>
              <td>Exceptions</td>
              <td>Run Time (ms)</td>
            </tr>
            <xsl:for-each select ="result">
              <tr>
                <xsl:attribute name="class">
                  <xsl:call-template name="TestResult">
                    <xsl:with-param name="pageName" select="relativePageName"/>
                    <xsl:with-param name="right" select = "counts/right"/>
                    <xsl:with-param name="wrong" select = "counts/wrong"/>
                    <xsl:with-param name="exceptions" select = "counts/exceptions"/>
                  </xsl:call-template>
                </xsl:attribute>
                <td>
                  <a>
                    <xsl:attribute name="href">#result<xsl:value-of select="position()"/></xsl:attribute>
                    <xsl:call-template name="FullPageName">
                      <xsl:with-param name="pageName" select="$title" />
                    </xsl:call-template>
                  </a>
                </td>
                <td>
                  <xsl:value-of select="counts/right"/>
                </td>
                <td>
                  <xsl:value-of select="counts/wrong"/>
                </td>
                <td>
                  <xsl:value-of select="counts/ignores"/>
                </td>
                <td>
                  <xsl:value-of select="counts/exceptions"/>
                </td>
                <td>
                  <xsl:value-of select="runTimeInMillis"/>
                </td>
              </tr>
            </xsl:for-each>
          </table>
        </xsl:if>
        <xsl:for-each select="result">
          <h2>
            <xsl:attribute name="class">
              <xsl:call-template name="TestResult">
                <xsl:with-param name="right" select = "counts/right"/>
                <xsl:with-param name="wrong" select = "counts/wrong"/>
                <xsl:with-param name="exceptions" select = "counts/exceptions"/>
              </xsl:call-template>
            </xsl:attribute>
            <a>
              <xsl:attribute name="id">#result<xsl:value-of select="position()"/></xsl:attribute>
              <xsl:call-template name="FullPageName">
                <xsl:with-param name="pageName" select="$title" />
              </xsl:call-template>
            </a>
            <div class="right">Started <xsl:value-of select="date"/></div></h2>
          <xsl:variable name="escaped_xml_start">
            <xsl:call-template name="replace">
              <xsl:with-param name="text" select="content" />
              <xsl:with-param name="find" select="'&lt;?'" />
              <xsl:with-param name="replacewith" select="'&amp;lt;?'" />
            </xsl:call-template>
          </xsl:variable>
          <xsl:variable name="escaped_xml_both">
            <xsl:call-template name="replace">
              <xsl:with-param name="text" select="$escaped_xml_start" />
              <xsl:with-param name="find" select="'?&gt;'" />
              <xsl:with-param name="replacewith" select="'?&amp;gt;'" />
            </xsl:call-template>
          </xsl:variable>

          <xsl:variable name="include_stripped_content">
            <xsl:call-template name="elementstripper" >
              <xsl:with-param name="text" select="$escaped_xml_both"/>
              <xsl:with-param name="startprefix" select="'Included page: '"/>
              <xsl:with-param name="starttag" select="'&lt;a href=&quot;'" />
              <xsl:with-param name="endtag" select="'&lt;/a&gt;'"/>
              <xsl:with-param name="includeproperty" select="true()"/>
              <xsl:with-param name="depth" select="0"/>
            </xsl:call-template>
          </xsl:variable>

          <xsl:variable name="removed_links">
            <xsl:call-template name="elementstripper" >
              <xsl:with-param name="text" select="$include_stripped_content"/>
              <xsl:with-param name="startprefix" />
              <xsl:with-param name="starttag" select="'&lt;a '" />
              <xsl:with-param name="endtag" select="'&lt;/a&gt;'"/>
              <xsl:with-param name="includeproperty" select="false()"/>
              <xsl:with-param name="depth" select="0"/>
            </xsl:call-template>
          </xsl:variable>

          <xsl:call-template name="elementstripper" >
            <xsl:with-param name="text" select="$removed_links"/>
            <xsl:with-param name="startprefix" />
            <xsl:with-param name="starttag" select="'&lt;ul&gt;'" />
            <xsl:with-param name="endtag" select="'&lt;/ul&gt;'"/>
            <xsl:with-param name="includeproperty" select="false()"/>
            <xsl:with-param name="depth" select="0"/>
          </xsl:call-template>
        </xsl:for-each>
      </body>
    </html>
  </xsl:template>

</xsl:stylesheet>
