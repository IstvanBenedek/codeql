/**
 * @name Using a non-constant time algorithm for comparing results of a cryptographic operation
 * @description When comparing results of a cryptographic operation, a constant time algorithm should be used.
 *              Otherwise, an attacker may be able to implement a timing attack.
 *              A successful attack may result in leaking secrets or authentication bypass.
 * @kind path-problem
 * @problem.severity error
 * @precision high
 * @id java/non-constant-time-crypto-comparison
 * @tags security
 *       external/cwe/cwe-208
 */

import java
import semmle.code.java.dataflow.TaintTracking
import semmle.code.java.dataflow.TaintTracking2
import semmle.code.java.dataflow.FlowSources
import DataFlow::PathGraph

private class ByteBuffer extends Class {
  ByteBuffer() { hasQualifiedName("java.nio", "ByteBuffer") }
}

abstract private class ProduceCryptoCall extends MethodAccess {
  Expr output;

  Expr output() { result = output }
}

private class ProduceMacCall extends ProduceCryptoCall {
  ProduceMacCall() {
    getMethod().hasQualifiedName("javax.crypto", "Mac", "doFinal") and
    (
      getMethod().getReturnType() instanceof Array and this = output
      or
      getMethod().getParameterType(0) instanceof Array and getArgument(0) = output
    )
  }
}

private class ProduceSignatureCall extends ProduceCryptoCall {
  ProduceSignatureCall() {
    getMethod().hasQualifiedName("java.security", "Signature", "sign") and
    (
      getMethod().getReturnType() instanceof Array and this = output
      or
      getMethod().getParameterType(0) instanceof Array and getArgument(0) = output
    )
  }
}

private class ProduceCiphertextCall extends ProduceCryptoCall {
  ProduceCiphertextCall() {
    getMethod().hasQualifiedName("javax.crypto", "Cipher", "doFinal") and
    (
      getMethod().getReturnType() instanceof Array and this = output
      or
      getMethod().getParameterType([0, 3]) instanceof Array and getArgument([0, 3]) = output
      or
      getMethod().getParameterType(1) instanceof ByteBuffer and
      getArgument(1) = output
    )
  }
}

private class UserInputInCryptoOperationConfig extends TaintTracking2::Configuration {
  UserInputInCryptoOperationConfig() { this = "UserInputInCryptoOperationConfig" }

  override predicate isSource(DataFlow::Node source) { source instanceof RemoteFlowSource }

  override predicate isSink(DataFlow::Node sink) {
    exists(ProduceCryptoCall call | call.getQualifier() = sink.asExpr())
  }

  override predicate isAdditionalTaintStep(DataFlow2::Node fromNode, DataFlow2::Node toNode) {
    exists(MethodAccess call, Method m |
      m = call.getMethod() and
      call.getQualifier() = toNode.asExpr() and
      call.getArgument(0) = fromNode.asExpr()
    |
      (
        m.hasQualifiedName("java.security", "Signature", "update")
        or
        m.hasQualifiedName("javax.crypto", ["Mac", "Cipher"], "update")
        or
        m.hasQualifiedName("javax.crypto", ["Mac", "Cipher"], "doFinal") and
        not m.hasStringSignature("doFinal(byte[],int)")
      )
    )
  }
}

private class CryptoOperationSource extends DataFlow::Node {
  Expr cryptoOperation;

  CryptoOperationSource() {
    exists(ProduceCryptoCall call | call.output() = this.asExpr() |
      cryptoOperation = call.getQualifier()
    )
  }

  predicate includesUserInput() {
    exists(
      DataFlow2::PathNode source, DataFlow2::PathNode sink, UserInputInCryptoOperationConfig config
    |
      config.hasFlowPath(source, sink)
    |
      sink.getNode().asExpr() = cryptoOperation
    )
  }
}

private class NonConstantTimeEqualsCall extends MethodAccess {
  NonConstantTimeEqualsCall() {
    getMethod()
        .hasQualifiedName("java.lang", "String", ["equals", "contentEquals", "equalsIgnoreCase"]) or
    getMethod().hasQualifiedName("java.nio", "ByteBuffer", ["equals", "compareTo"])
  }
}

private class NonConstantTimeComparisonCall extends StaticMethodAccess {
  NonConstantTimeComparisonCall() {
    getMethod().hasQualifiedName("java.util", "Arrays", ["equals", "deepEquals"]) or
    getMethod().hasQualifiedName("java.util", "Objects", "deepEquals") or
    getMethod()
        .hasQualifiedName("org.apache.commons.lang3", "StringUtils",
          ["equals", "equalsAny", "equalsAnyIgnoreCase", "equalsIgnoreCase"])
  }
}

private class UserInputInComparisonConfig extends TaintTracking2::Configuration {
  UserInputInComparisonConfig() { this = "UserInputInComparisonConfig" }

  override predicate isSource(DataFlow::Node source) { source instanceof RemoteFlowSource }

  override predicate isSink(DataFlow::Node sink) {
    exists(NonConstantTimeEqualsCall call |
      sink.asExpr() = [call.getAnArgument(), call.getQualifier()]
    )
    or
    exists(NonConstantTimeComparisonCall call | sink.asExpr() = call.getAnArgument())
  }
}

private predicate looksLikeConstant(Expr expr) {
  expr.isCompileTimeConstant()
  or
  expr.(VarAccess).getVariable().isFinal() and expr.getType() instanceof TypeString
}

/**
 * A sink that compares input using a non-constant time algorithm.
 */
private class NonConstantTimeComparisonSink extends DataFlow::Node {
  Expr anotherParameter;

  NonConstantTimeComparisonSink() {
    (
      exists(NonConstantTimeEqualsCall call |
        this.asExpr() = call.getQualifier() and
        anotherParameter = call.getAnArgument()
        or
        this.asExpr() = call.getAnArgument() and
        anotherParameter = call.getQualifier()
      )
      or
      exists(NonConstantTimeComparisonCall call |
        call.getAnArgument() = this.asExpr() and
        (
          this.asExpr() = call.getArgument(0) and anotherParameter = call.getArgument(1)
          or
          this.asExpr() = call.getArgument(1) and anotherParameter = call.getArgument(0)
        )
      )
    ) and
    not looksLikeConstant(anotherParameter)
  }

  predicate includesUserInput() {
    exists(UserInputInComparisonConfig config |
      config.hasFlowTo(DataFlow2::exprNode(anotherParameter))
    )
  }
}

/**
 * A configuration that tracks data flow from cryptographic operations
 * to methods that compare data using a non-constant time algorithm.
 */
private class NonConstantTimeCryptoComparisonConfig extends TaintTracking::Configuration {
  NonConstantTimeCryptoComparisonConfig() { this = "NonConstantTimeCryptoComparisonConfig" }

  override predicate isSource(DataFlow::Node source) { source instanceof CryptoOperationSource }

  override predicate isSink(DataFlow::Node sink) { sink instanceof NonConstantTimeComparisonSink }
}

from DataFlow::PathNode source, DataFlow::PathNode sink, NonConstantTimeCryptoComparisonConfig conf
where
  conf.hasFlowPath(source, sink) and
  (
    source.getNode().(CryptoOperationSource).includesUserInput() or
    sink.getNode().(NonConstantTimeComparisonSink).includesUserInput()
  )
select sink.getNode(), source, sink,
  "Using a non-constant time algorithm for comparing results of a cryptographic operation."
