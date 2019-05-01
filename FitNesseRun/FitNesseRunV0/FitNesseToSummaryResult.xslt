<?xml version="1.0" encoding="utf-8"?>
<!--
 Copyright 2013-2017 Rik Essenius

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
  <xsl:output method="xml" indent="yes" />

  <!-- Assertions -->
  <xsl:variable name="GlobalRightCount" select="sum(//result/counts/right)"/>
  <xsl:variable name="GlobalIgnoresCount" select="sum(//result/counts/ignores)"/>
  <xsl:variable name="GlobalWrongCount" select="sum(//result/counts/wrong)"/>
  <xsl:variable name="GlobalExceptionsCount" select="sum(//result/counts/exceptions)"/>
  <xsl:variable name="GlobalFailureCount" select="$GlobalWrongCount + $GlobalExceptionsCount"/>
  
  <!-- Test Pages -->
  <xsl:variable name="FinalRightCount" select="sum(//finalCounts/right)"/>
  <xsl:variable name="FinalIgnoresCount" select="sum(//finalCounts/ignores)"/>
  <xsl:variable name="FinalWrongCount" select="sum(//finalCounts/wrong)"/>
  <xsl:variable name="FinalExceptionsCount" select="sum(//finalCounts/exceptions)"/>
  <xsl:variable name="FinalCount" select="$FinalRightCount + $FinalIgnoresCount + $FinalWrongCount + $FinalExceptionsCount"/>

<!-- the test for rootpath is to force the transformation to return <TestName/> and not <TestName></TestName> with empty rootPath. 
     The test for $reponse.RootPath is to work around a bug in the XML format for FitNesse 20121220 -->
  <xsl:template match="testResults">
    <SummaryResult>
      <TestName>
        <xsl:if test="rootPath">
          <xsl:choose>
            <xsl:when test="rootPath='$response.RootPath'"><xsl:value-of select="result/relativePageName"/></xsl:when>
            <xsl:otherwise><xsl:value-of select="rootPath"/></xsl:otherwise>
          </xsl:choose>
        </xsl:if> 
      </TestName>
      <xsl:call-template name="TestResult">
        <xsl:with-param name="right" select="$GlobalRightCount"/>
        <xsl:with-param name="wrong" select="$GlobalWrongCount"/>
        <xsl:with-param name="exceptions" select="$GlobalExceptionsCount"/>
      </xsl:call-template>
      <ErrorMessage>
        <xsl:if test="executionLog/exception">
          <xsl:value-of select="executionLog/exception"/><xsl:text>&#xa;</xsl:text>
        </xsl:if>
        <xsl:if test="$FinalCount>0">
          <xsl:call-template name="SummaryCount">
            <xsl:with-param name="header">Test Pages</xsl:with-param>
            <xsl:with-param name="right" select="$FinalRightCount"/>
            <xsl:with-param name="wrong" select="$FinalWrongCount"/>
            <xsl:with-param name="ignores" select="$FinalIgnoresCount"/>
            <xsl:with-param name="exceptions" select="$FinalExceptionsCount"/>
          </xsl:call-template>
        </xsl:if>
        <xsl:call-template name="SummaryCount">
          <xsl:with-param name="header">Assertions</xsl:with-param>
          <xsl:with-param name="right" select="$GlobalRightCount"/>
          <xsl:with-param name="wrong" select="$GlobalWrongCount"/>
          <xsl:with-param name="ignores" select="$GlobalIgnoresCount"/>
          <xsl:with-param name="exceptions" select="$GlobalExceptionsCount"/>
        </xsl:call-template>
        <xsl:if test="/testResults/totalRunTimeInMillis">
          <xsl:text>Run time: </xsl:text><xsl:value-of select="/testResults/totalRunTimeInMillis div 1000"/><xsl:text> s.</xsl:text>
        </xsl:if>
      </ErrorMessage>
      <xsl:if test="result/content">
         <DetailedResultsFile>DetailedResults.html</DetailedResultsFile>
      </xsl:if>
      <InnerTests>
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
          <InnerTest>
            <TestName>
              <xsl:value-of select="$FullTestName"/>
            </TestName>
            <xsl:call-template name="TestResult">
              <xsl:with-param name="right" select="sum(counts/right)"/>
              <xsl:with-param name="wrong" select="sum(counts/wrong)"/>
              <xsl:with-param name="exceptions" select="sum(counts/exceptions)"/>
            </xsl:call-template>
            <ErrorMessage>
              <xsl:call-template name="SummaryCount">
                <xsl:with-param name="header">Assertions</xsl:with-param>
                <xsl:with-param name="right" select="sum(counts/right)"/>
                <xsl:with-param name="wrong" select="sum(counts/wrong)"/>
                <xsl:with-param name="ignores" select="sum(counts/ignores)"/>
                <xsl:with-param name="exceptions" select="sum(counts/exceptions)"/>
              </xsl:call-template>
              <xsl:text>Run time: </xsl:text><xsl:value-of select="runTimeInMillis div 1000"/><xsl:text> s.</xsl:text>
            </ErrorMessage>
          </InnerTest>
        </xsl:for-each>
      </InnerTests>
    </SummaryResult>
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
    <TestResult>
    <xsl:choose>
      <xsl:when test="$wrong &gt; 0">Failed</xsl:when>
      <xsl:when test="$exceptions &gt; 0">Error</xsl:when>
      <xsl:when test="$right &gt; 0">Passed</xsl:when>
      <xsl:otherwise>Inconclusive</xsl:otherwise>
    </xsl:choose>
    </TestResult>
  </xsl:template>

  <xsl:template match="*">
    <SummaryResult>
      <TestName>Unknown</TestName>
      <ErrorMessage>Unable to interpret FitNesse result. It does not contain a testResults root element</ErrorMessage>
    </SummaryResult>
  </xsl:template>
</xsl:stylesheet>
