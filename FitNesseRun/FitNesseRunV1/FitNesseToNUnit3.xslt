<?xml version="1.0" encoding="utf-8"?>
<!--
 Copyright 2017-2020 Rik Essenius

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
         public string AddSecondsToTimestamp(string timestamp, double seconds)
         {
            if (string.IsNullOrEmpty(timestamp)) return string.Empty;
            if (double.IsNaN(seconds)) seconds = 0;
            var datetime = DateTime.Parse(timestamp);
            return datetime.AddSeconds(seconds).ToUniversalTime().ToString("o");
         }
         
         public string Zulu(string timestamp)
         {
            return AddSecondsToTimestamp(timestamp, 0);
         }
         
         public string Nz(string value, string defaultValue)
         {
            return string.IsNullOrEmpty(value) ? defaultValue : value;
         }
         
         public bool EndsWith(string value, string valueToSearch)
         {
            return value.EndsWith(valueToSearch);
         }
    ]]>
  </msxsl:script>

  <xsl:output method="xml" indent="yes" />
  <xsl:param name="Now" />

  <xsl:variable name="AssertionsRightCount" select="sum(testResults/result/counts/right)" />
  <xsl:variable name="AssertionsIgnoresCount" select="sum(testResults/result/counts/ignores)" />
  <xsl:variable name="AssertionsWrongCount" select="sum(testResults/result/counts/wrong)" />
  <xsl:variable name="AssertionsExceptionsCount" select="sum(testResults/result/counts/exceptions)" />
  <xsl:variable name="AssertionsFailureCount" select="$AssertionsWrongCount + $AssertionsExceptionsCount" />
  <xsl:variable name="AssertionsCount" select="$AssertionsFailureCount + $AssertionsRightCount + $AssertionsIgnoresCount" />

  <xsl:variable name="PagesRightCount" select="sum(testResults/finalCounts/right)" />
  <xsl:variable name="PagesIgnoresCount" select="sum(testResults/finalCounts/ignores)" />
  <xsl:variable name="PagesWrongCount" select="sum(testResults/finalCounts/wrong)" />
  <xsl:variable name="PagesExceptionsCount" select="sum(testResults/finalCounts/exceptions)" />
  <xsl:variable name="PagesFailureCount" select="$PagesWrongCount + $PagesExceptionsCount" />
  <xsl:variable name="PagesCount" select="$PagesRightCount + $PagesIgnoresCount + $PagesWrongCount + $PagesExceptionsCount" />
  <xsl:variable name="Duration" select="user:Nz(testResults/totalRunTimeInMillis, 0) div 1000.0" />
  <xsl:variable name="StartTime">
    <xsl:choose>
      <xsl:when test="testResults/result[1]/date">
        <xsl:value-of select="user:Zulu(testResults/result[1]/date)"/>
      </xsl:when>
      <xsl:otherwise>
        <xsl:value-of select="user:AddSecondsToTimestamp($Now, -$Duration)"/>
      </xsl:otherwise>
    </xsl:choose>
  </xsl:variable>

  <xsl:variable name="EndTime" select="user:AddSecondsToTimestamp($StartTime, $Duration)"/>

  <!-- The test for $reponse.RootPath is to work around a bug in the XML format for FitNesse 20121220 -->
  <xsl:template match="testResults">
    <xsl:variable name="title">
      <xsl:choose>
        <xsl:when test="rootPath='$response.RootPath'">
          <xsl:value-of select="result/relativePageName"/>
        </xsl:when>
        <xsl:when test="rootPath">
          <xsl:value-of select="rootPath"/>
        </xsl:when>
        <xsl:otherwise>
          <xsl:value-of select="'FitNesse'"/>
        </xsl:otherwise>
      </xsl:choose>
    </xsl:variable>

    <test-run>
      <xsl:attribute name="name"><xsl:value-of select="$title"/>-Run</xsl:attribute>
      <xsl:call-template name="PageSummaryAttributes"/>
      <xsl:if test="FitNesseVersion">
      <xsl:attribute name="engine-version">FitNesse <xsl:value-of select="FitNesseVersion"/>
      </xsl:attribute>
      </xsl:if>
      
      <xsl:if test="executionLog/command">
        <command-line>
          <xsl:text disable-output-escaping="yes">&lt;![CDATA[</xsl:text>
          <xsl:value-of select="executionLog/command"/>
          <xsl:text disable-output-escaping="yes">]]&gt;</xsl:text>
        </command-line>
      </xsl:if>
      <test-suite type="Assembly" runstate="Runnable">
        <xsl:attribute name="name">
          <xsl:value-of select="$title"/>
        </xsl:attribute>
        <xsl:attribute name="fullName">
          <xsl:value-of select="$title"/>
        </xsl:attribute>
        <xsl:call-template name="PageSummaryAttributes"/>
        <environment/>
        <xsl:if test="executionLog/testSystem">
          <settings>
            <setting name="TestSystem">
              <xsl:attribute name="value">
                <xsl:value-of select="executionLog/testSystem"/>
              </xsl:attribute>
            </setting>
          </settings>
        </xsl:if>
          <xsl:if test="executionLog/exitCode">
            <properties>
              <property name="exit-code">
                <xsl:attribute name="value">
                  <xsl:value-of select="executionLog/exitCode"/>
                </xsl:attribute>
              </property>
            </properties>
          </xsl:if>
        <xsl:call-template name="FailureSection">
          <xsl:with-param name="errorMessage">
            <xsl:if test="executionLog/exception">
              <xsl:value-of select="executionLog/exception"/>
              <xsl:text>&#xa;</xsl:text>
            </xsl:if>
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
          </xsl:with-param>
          <xsl:with-param name="stackTrace" select="executionLog/stackTrace"/>
        </xsl:call-template>
        <results>
          <xsl:if test="not(result)">
            <xsl:call-template name="ErrorTestCase">
              <xsl:with-param name="errorMessage" select="executionLog/exception"/>
              <xsl:with-param name="stackTrace" select="executionLog/stackTrace"/>
            </xsl:call-template>
          </xsl:if>
          <xsl:for-each select="result">
            <xsl:variable name="FullTestName">
              <xsl:if test="pageHistoryLink">
                <xsl:value-of select="substring-before(pageHistoryLink,'?')"/>
              </xsl:if>
            </xsl:variable>
            <xsl:variable name="UsedTestName">
              <xsl:choose>
                <xsl:when test="user:EndsWith($title, relativePageName) and ($FullTestName='' or $FullTestName=$title)">
                  <xsl:value-of select="relativePageName"/>
                </xsl:when>
                <xsl:when test="starts-with($FullTestName,$title)">
                  <xsl:value-of select="substring-after($FullTestName,$title)"/>
                </xsl:when>
                <xsl:otherwise>
                  <xsl:value-of select="$FullTestName"/>
                </xsl:otherwise>                
              </xsl:choose>
            </xsl:variable>
            <test-case>
              <xsl:attribute name="name">
                <xsl:value-of select="$UsedTestName"/>
              </xsl:attribute>
              <xsl:attribute name="fullname">
                <xsl:value-of select="$UsedTestName"/>
              </xsl:attribute>
              <xsl:attribute name="result">
                <xsl:call-template name="TestResult">
                  <xsl:with-param name="pageName" select="relativePageName"/>
                  <xsl:with-param name="right" select="sum(counts/right)"/>
                  <xsl:with-param name="wrong" select="sum(counts/wrong)"/>
                  <xsl:with-param name="exceptions" select="sum(counts/exceptions)"/>
                  <xsl:with-param name="suiteExceptions" select="0"/>
                </xsl:call-template>
              </xsl:attribute>
              <xsl:if test="sum(counts/error) &gt; 0">
                <xsl:attribute name="label">Error</xsl:attribute>
              </xsl:if>
              <xsl:if test="date">
                <xsl:attribute name="start-time">
                  <xsl:value-of select="user:Zulu(date)"/>
                </xsl:attribute>
              </xsl:if>
              <xsl:attribute name="duration">
                <xsl:value-of select="runTimeInMillis div 1000.0"/>
              </xsl:attribute>
              <xsl:attribute name="asserts">
                <xsl:value-of select="sum(counts/*/text())"/>
              </xsl:attribute>

              <xsl:call-template name="FailureSection">
                <xsl:with-param name="errorMessage">
                  <xsl:call-template name="SummaryCount">
                    <xsl:with-param name="header">Assertions</xsl:with-param>
                    <xsl:with-param name="right" select="sum(counts/right)"/>
                    <xsl:with-param name="wrong" select="sum(counts/wrong)"/>
                    <xsl:with-param name="ignores" select="sum(counts/ignores)"/>
                    <xsl:with-param name="exceptions" select="sum(counts/exceptions)"/>
                  </xsl:call-template>
                </xsl:with-param>
              </xsl:call-template>
            </test-case>
          </xsl:for-each>
        </results>
        <attachments>
          <attachment>
            <filePath/>
            <description>Raw test results from FitNesse</description>
          </attachment>
        </attachments>
      </test-suite>
    </test-run>
  </xsl:template>

  <xsl:template name="PageSummaryAttributes">
    <xsl:attribute name="result">
      <xsl:call-template name="TestResult">
        <xsl:with-param name="right" select="$AssertionsRightCount"/>
        <xsl:with-param name="wrong" select="$AssertionsWrongCount"/>
        <xsl:with-param name="exceptions" select="$AssertionsExceptionsCount"/>
        <xsl:with-param name="suiteExceptions" select="$PagesExceptionsCount"/>
      </xsl:call-template>
    </xsl:attribute>
    <xsl:attribute name="testcasecount">
      <xsl:value-of select="$PagesCount"/>
    </xsl:attribute>
    <xsl:attribute name="total">
      <xsl:value-of select="$PagesCount"/>
    </xsl:attribute>
    <xsl:attribute name="passed">
      <xsl:value-of select="$PagesRightCount"/>
    </xsl:attribute>
    <xsl:attribute name="failed">
      <xsl:value-of select="$PagesFailureCount"/>
    </xsl:attribute>
    <xsl:attribute name="inconclusive">
      <xsl:value-of select="$PagesIgnoresCount"/>
    </xsl:attribute>
    <xsl:attribute name="skipped">0</xsl:attribute>
    <xsl:attribute name="asserts">
      <xsl:value-of select="$AssertionsCount"/>
    </xsl:attribute>
    <xsl:attribute name="start-time">
      <xsl:value-of select="$StartTime"/>
    </xsl:attribute>
    <xsl:attribute name="end-time">
      <xsl:value-of select="$EndTime"/>
    </xsl:attribute>
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
    <xsl:param name="pageName"/>
    <xsl:param name="right"/>
    <xsl:param name="wrong"/>
    <xsl:param name="exceptions"/>
    <xsl:param name="suiteExceptions"/>
    <xsl:choose>
      <xsl:when test="$wrong + $exceptions + $suiteExceptions &gt; 0">Failed</xsl:when>
      <xsl:when test="$right &gt; 0">Passed</xsl:when>
      <xsl:otherwise>
        <xsl:choose>
          <xsl:when test="$pageName='SetUp' or $pageName='TearDown' or $pageName='SuiteSetUp' or $pageName='SuiteTearDown'">Passed</xsl:when>
          <xsl:otherwise>Inconclusive</xsl:otherwise>
        </xsl:choose>
      </xsl:otherwise>
    </xsl:choose>
  </xsl:template>

  <xsl:template name="ErrorTestCase">
    <xsl:param name="errorMessage"/>
    <xsl:param name="stackTrace"/>
    <test-case name="ErrorTestCase" fullname="ErrorTestCase" result="Failed" label="Error" asserts="0">
      <xsl:attribute name="start-time">
        <xsl:value-of select="$StartTime" />
      </xsl:attribute>
      <xsl:attribute name="duration">
        <xsl:value-of select="$Duration"/>
      </xsl:attribute>
      <xsl:call-template name="FailureSection">
        <xsl:with-param name="errorMessage" select="$errorMessage" />
        <xsl:with-param name="stackTrace" select="$stackTrace" />
      </xsl:call-template>
    </test-case>
  </xsl:template>

  <xsl:template name="FailureSection">
    <xsl:param name="errorMessage"/>
    <xsl:param name="stackTrace"/>
    <xsl:if test="$errorMessage">
      <failure>
        <message>
          <xsl:text disable-output-escaping="yes">&lt;![CDATA[</xsl:text>
          <xsl:value-of disable-output-escaping="yes" select="$errorMessage"/>
          <xsl:text disable-output-escaping="yes">]]&gt;</xsl:text>
        </message>
        <xsl:if test="$stackTrace">
          <stack-trace>
            <xsl:text disable-output-escaping="yes">&lt;![CDATA[</xsl:text>
            <xsl:value-of disable-output-escaping="yes" select="$stackTrace"/>
            <xsl:text disable-output-escaping="yes">]]&gt;</xsl:text>
          </stack-trace>
        </xsl:if>
      </failure>
    </xsl:if>
  </xsl:template>

  <xsl:template match="*">
    <xsl:variable name="interpretError">Unable to interpret FitNesse result. It does not contain a testResults root element</xsl:variable>
    <test-run name="InvalidResponseFromFitNesse" result="Failed">
      <xsl:call-template name="PageSummaryAttributes"/>
      <test-suite name="InvalidResponseFromFitNesse" result="Failed">
        <xsl:call-template name="PageSummaryAttributes"/>
        <xsl:call-template name="FailureSection">
          <xsl:with-param name="errorMessage" select="$interpretError"/>
        </xsl:call-template>
        <results>
          <xsl:call-template name="ErrorTestCase">
            <xsl:with-param name="errorMessage" select="$interpretError"/>
            <xsl:with-param name="stackTrace" select="'FitNesseToNUnit3.xslt xsl:template match=*'"/>
          </xsl:call-template>
        </results>
      </test-suite>
    </test-run>
  </xsl:template>

</xsl:stylesheet>
