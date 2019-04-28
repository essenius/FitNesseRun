<?xml version="1.0" encoding="utf-8"?>
<!--
 Copyright 2017 Rik Essenius

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
    xmlns:user="urn:my-scripts"
    exclude-result-prefixes="msxsl user"
    >

  <msxsl:script language="C#" implements-prefix="user">
    <![CDATA[              
         public string ToUtc(string timestamp, string format)
         {
            if (string.IsNullOrEmpty(timestamp)) return string.Empty;
            var datetime = DateTime.Parse(timestamp);
            return datetime.ToUniversalTime().ToString(format);
         }   
    ]]>
  </msxsl:script>

  <xsl:output method="xml" indent="yes" />

  <!-- the test for rootpath is to force the transformation to return <TestName/> and not <TestName></TestName> with empty rootPath. 
     The test for $reponse.RootPath is to work around a bug in the XML format for FitNesse 20121220 -->
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
    <xsl:variable name="AssertionsRightCount" select="sum(result/counts/right)"/>
    <xsl:variable name="AssertionsIgnoresCount" select="sum(result/counts/ignores)"/>
    <xsl:variable name="AssertionsWrongCount" select="sum(result/counts/wrong)"/>
    <xsl:variable name="AssertionsExceptionsCount" select="sum(result/counts/exceptions)"/>
    <xsl:variable name="AssertionsFailureCount" select="$AssertionsWrongCount + $AssertionsExceptionsCount"/>
    <xsl:variable name="AssertionsCount" select="$AssertionsFailureCount + $AssertionsRightCount + $AssertionsIgnoresCount"/>
  
    <xsl:variable name="PagesRightCount" select="sum(finalCounts/right)"/>
    <xsl:variable name="PagesIgnoresCount" select="sum(finalCounts/ignores)"/>
    <xsl:variable name="PagesWrongCount" select="sum(finalCounts/wrong)"/>
    <xsl:variable name="PagesExceptionsCount" select="sum(finalCounts/exceptions)"/>
    <xsl:variable name="PagesCount" select="$PagesRightCount + $PagesIgnoresCount + $PagesWrongCount + $PagesExceptionsCount"/>
    
    <test-results>
      <xsl:attribute name="name"><xsl:value-of select="$title"/>Results</xsl:attribute>
      <xsl:attribute name="date"><xsl:value-of select="user:ToUtc(result[1]/date, 'yyyy-MM-dd')"/></xsl:attribute>
      <xsl:attribute name="time"><xsl:value-of select="user:ToUtc(result[1]/date, 'HH:mm:ss')"/></xsl:attribute>
      <test-suite executed="true">
        <xsl:attribute name="name"><xsl:value-of select="$title"/></xsl:attribute>
        <xsl:attribute name="time"><xsl:value-of select="totalRunTimeInMillis div 1000.0"/></xsl:attribute>
        <xsl:attribute name="asserts"><xsl:value-of select="$AssertionsCount"/></xsl:attribute>
        <xsl:attribute name="success">
          <xsl:value-of select="sum(finalCounts/wrong) + sum(finalCounts/exceptions) = 0"/>
        </xsl:attribute>
        <xsl:attribute name="result">
          <xsl:call-template name="TestResult">
            <xsl:with-param name="right" select="$AssertionsRightCount"/>
            <xsl:with-param name="wrong" select="$AssertionsWrongCount"/>
            <xsl:with-param name="exceptions" select="$AssertionsExceptionsCount"/>
          </xsl:call-template>
        </xsl:attribute>
        <Properties>
          <Property name="FitNesseVersion"><xsl:value-of select="FitNesseVersion"/></Property>
          <Property name="TestSystem"><xsl:value-of select="executionLog/testSystem"/></Property>
          <Property name="Summary">
            <xsl:if test="$PagesCount>0">
              <xsl:call-template name="SummaryCount">
                <xsl:with-param name="header">Test Pages</xsl:with-param>
                <xsl:with-param name="right" select="$PagesRightCount"/>
                <xsl:with-param name="wrong" select="$PagesWrongCount"/>
                <xsl:with-param name="ignores" select="$PagesIgnoresCount"/>
                <xsl:with-param name="exceptions" select="$PagesExceptionsCount"/>
              </xsl:call-template>
            </xsl:if>
            <xsl:call-template name="SummaryCount">
              <xsl:with-param name="header">Assertions</xsl:with-param>
              <xsl:with-param name="right" select="$AssertionsRightCount"/>
              <xsl:with-param name="wrong" select="$AssertionsWrongCount"/>
              <xsl:with-param name="ignores" select="$AssertionsIgnoresCount"/>
              <xsl:with-param name="exceptions" select="$AssertionsExceptionsCount"/>
            </xsl:call-template>
          </Property>
          <Property name="Command"><xsl:value-of select="executionLog/command"/></Property>
          <Property name="ExitCode"><xsl:value-of select="executionLog/exitCode"/></Property>
          <xsl:if test="normalize-space(executionLog/stdOut) !=''">
            <Property name="OutputStream"><xsl:value-of select="executionLog/stdOut"/></Property>
          </xsl:if>
          <xsl:if test="normalize-space(executionLog/stdErr) !=''">
            <Property name="ErrorStram"><xsl:value-of select="executionLog/stdErr"/></Property>
          </xsl:if>
        </Properties>
        <results>
          <xsl:for-each select="result">
            <xsl:variable name="FullTestName">
              <xsl:choose>
                <xsl:when test="pageHistoryLink">
                  <xsl:value-of select="substring-before(pageHistoryLink,'?')"/>
                </xsl:when>
                <xsl:otherwise>
                  <xsl:value-of select="relativePageName"/>
                </xsl:otherwise>
              </xsl:choose>
            </xsl:variable>
            <test-case executed="True">
              <xsl:variable name="Success" select="sum(counts/wrong) + sum(counts/exceptions) = 0"/>
              <xsl:attribute name="name"><xsl:value-of select="$FullTestName"/></xsl:attribute>
              <xsl:attribute name="time"><xsl:value-of select="runTimeInMillis div 1000.0"/></xsl:attribute>
              <xsl:attribute name="asserts"><xsl:value-of select="sum(counts/*/text())"/></xsl:attribute>
              <xsl:attribute name="success"><xsl:value-of select="$Success"/></xsl:attribute>
              <xsl:if test="not($Success)">
                <failure>
                  <message>
                    <xsl:call-template name="SummaryCount">
                      <xsl:with-param name="header">Assertions</xsl:with-param>
                      <xsl:with-param name="right" select="sum(counts/right)"/>
                      <xsl:with-param name="wrong" select="sum(counts/wrong)"/>
                      <xsl:with-param name="ignores" select="sum(counts/ignores)"/>
                      <xsl:with-param name="exceptions" select="sum(counts/exceptions)"/>
                    </xsl:call-template>
                  </message>
                </failure>
              </xsl:if>
              <properties>
                <property name="TestResult">
                  <xsl:attribute name="value">
                    <xsl:call-template name="TestResult">
                      <xsl:with-param name="right" select="sum(counts/right)"/>
                      <xsl:with-param name="wrong" select="sum(counts/wrong)"/>
                      <xsl:with-param name="exceptions" select="sum(counts/exceptions)"/>
                    </xsl:call-template>
                  </xsl:attribute> 
                </property>
                <property name="Summary">
                  <xsl:call-template name="SummaryCount">
                    <xsl:with-param name="header">Assertions</xsl:with-param>
                    <xsl:with-param name="right" select="sum(counts/right)"/>
                    <xsl:with-param name="wrong" select="sum(counts/wrong)"/>
                    <xsl:with-param name="ignores" select="sum(counts/ignores)"/>
                    <xsl:with-param name="exceptions" select="sum(counts/exceptions)"/>
                  </xsl:call-template>                  
                </property>
                <!--<Property name="HtmlResult"><xsl:value-of select="content"/></Property> -->
              </properties>
            </test-case>
          </xsl:for-each>
        </results>
      </test-suite>
    </test-results>
  </xsl:template>

  <xsl:template name="SummaryCount">
    <xsl:param name="header"/>
    <xsl:param name="right"/>
    <xsl:param name="wrong"/>
    <xsl:param name="ignores"/>
    <xsl:param name="exceptions"/>
      <xsl:text/>
      <xsl:value-of select="$header"/>
      <xsl:text>: </xsl:text>
      <xsl:value-of select ="$right"/>
      <xsl:text> right, </xsl:text>
      <xsl:value-of select ="$wrong"/>
      <xsl:text> wrong, </xsl:text>
      <xsl:value-of select ="$ignores"/>
      <xsl:text> ignores, </xsl:text>
      <xsl:value-of select ="$exceptions"/>
      <xsl:text> exceptions. </xsl:text>
  </xsl:template>

  <xsl:template name="TestResult">
    <xsl:param name="right"/>
    <xsl:param name="wrong"/>
    <xsl:param name="exceptions"/>
    <xsl:choose>
      <xsl:when test="$wrong &gt; 0">Failed</xsl:when>
      <xsl:when test="$exceptions &gt; 0">Error</xsl:when>
      <xsl:when test="$right &gt; 0">Passed</xsl:when>
      <xsl:otherwise>Inconclusive</xsl:otherwise>
    </xsl:choose>
  </xsl:template>

  <xsl:template match="*">
    <error>Input file not in FitNesse format</error>
  </xsl:template>

</xsl:stylesheet>
