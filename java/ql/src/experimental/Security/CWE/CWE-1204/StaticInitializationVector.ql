/**
 * @name Using a static initialization vector for encryption
 * @description A cipher needs an initialization vector (IV) in some cases,
 *              for example, when CBC or GCM modes are used. IVs are used to randomize the encryption,
 *              therefore they should be unique and ideally unpredictable.
 *              Otherwise, the same plaintexts result in same ciphertexts under a given secret key.
 *              If a static IV is used for encryption, this lets an attacker learn
 *              if the same data pieces are transfered or stored,
 *              or this can help the attacker run a dictionary attack.
 * @kind path-problem
 * @problem.severity warning
 * @precision high
 * @id java/static-initialization-vector
 * @tags security
 *       external/cwe/cwe-329
 *       external/cwe/cwe-1204
 */

import java
import semmle.code.java.dataflow.TaintTracking
import semmle.code.java.dataflow.TaintTracking2
import DataFlow::PathGraph

/**
 * Holds if `array` is initialized only with constants, for example,
 * `new byte[8]` or `new byte[] { 1, 2, 3, 4, 5, 6, 7, 8 }`.
 */
private predicate initializedWithConstants(ArrayCreationExpr array) {
  not exists(array.getInit())
  or
  forex(Expr element | element = array.getInit().getAChildExpr() |
    element instanceof CompileTimeConstantExpr
  )
}

/**
 * An expression that creates a byte array that is initialized with constants.
 */
private class StaticByteArrayCreation extends ArrayCreationExpr {
  StaticByteArrayCreation() {
    this.getType().(Array).getElementType().(PrimitiveType).getName() = "byte" and
    initializedWithConstants(this)
  }
}

/** Defines a sub-set of expressions that update an array. */
private class ArrayUpdate extends Expr {
  Expr array;

  ArrayUpdate() {
    exists(Assignment assign, ArrayAccess arrayAccess | arrayAccess = assign.getDest() |
      assign = this and
      arrayAccess.getArray() = array and
      not assign.getSource() instanceof CompileTimeConstantExpr
    )
    or
    exists(StaticMethodAccess ma |
      ma.getMethod().hasQualifiedName("java.lang", "System", "arraycopy") and
      ma = this and
      ma.getArgument(2) = array
    )
    or
    exists(StaticMethodAccess ma |
      ma.getMethod().hasQualifiedName("java.util", "Arrays", "copyOf") and
      ma = this and
      ma = array
    )
    or
    exists(MethodAccess ma, Method m |
      m = ma.getMethod() and
      ma = this and
      ma.getArgument(0) = array
    |
      m.hasQualifiedName("java.io", "InputStream", "read") or
      m.hasQualifiedName("java.nio", "ByteBuffer", "get") or
      m.hasQualifiedName("java.security", "SecureRandom", "nextBytes") or
      m.hasQualifiedName("java.util", "Random", "nextBytes")
    )
  }

  /** Returns the updated array. */
  Expr getArray() { result = array }
}

/**
 * A config that tracks dataflow from creating an array to an operation that updates it.
 */
private class ArrayUpdateConfig extends TaintTracking2::Configuration {
  ArrayUpdateConfig() { this = "ArrayUpdateConfig" }

  override predicate isSource(DataFlow::Node source) {
    source.asExpr() instanceof StaticByteArrayCreation
  }

  override predicate isSink(DataFlow::Node sink) {
    exists(ArrayUpdate update | update.getArray() = sink.asExpr())
  }
}

/**
 * A source that defines an array that doesn't get updated.
 */
private class StaticInitializationVectorSource extends DataFlow::Node {
  StaticInitializationVectorSource() {
    exists(StaticByteArrayCreation array | array = this.asExpr() |
      not exists(ArrayUpdate update, ArrayUpdateConfig config |
        config.hasFlow(DataFlow2::exprNode(array), DataFlow2::exprNode(update.getArray()))
      )
    )
  }
}

/**
 * A config that tracks initialization of a cipher for encryption.
 */
private class EncryptionModeConfig extends TaintTracking2::Configuration {
  EncryptionModeConfig() { this = "EncryptionModeConfig" }

  override predicate isSource(DataFlow::Node source) {
    source.asExpr().(VarAccess).getVariable().hasName("ENCRYPT_MODE")
  }

  override predicate isSink(DataFlow::Node sink) {
    exists(MethodAccess ma, Method m | m = ma.getMethod() |
      m.hasQualifiedName("javax.crypto", "Cipher", "init") and
      ma.getArgument(0) = sink.asExpr()
    )
  }
}

/**
 * A sink that initializes a cipher for encryption with unsafe parameters.
 */
private class EncryptionInitializationSink extends DataFlow::Node {
  EncryptionInitializationSink() {
    exists(MethodAccess ma, Method m, EncryptionModeConfig config | m = ma.getMethod() |
      m.hasQualifiedName("javax.crypto", "Cipher", "init") and
      m.getParameterType(2)
          .(RefType)
          .hasQualifiedName("java.security.spec", "AlgorithmParameterSpec") and
      ma.getArgument(2) = this.asExpr() and
      config.hasFlowToExpr(ma.getArgument(0))
    )
  }
}

/**
 * Holds if `fromNode` to `toNode` is a dataflow step
 * that creates cipher's parameters with initialization vector.
 */
private predicate createInitializationVectorSpecStep(DataFlow::Node fromNode, DataFlow::Node toNode) {
  exists(ConstructorCall cc, RefType type |
    cc = toNode.asExpr() and type = cc.getConstructedType()
  |
    type.hasQualifiedName("javax.crypto.spec", "IvParameterSpec") and
    cc.getArgument(0) = fromNode.asExpr()
    or
    type.hasQualifiedName("javax.crypto.spec", ["GCMParameterSpec", "RC2ParameterSpec"]) and
    cc.getArgument(1) = fromNode.asExpr()
    or
    type.hasQualifiedName("javax.crypto.spec", "RC5ParameterSpec") and
    cc.getArgument(3) = fromNode.asExpr()
  )
}

/**
 * A config that tracks dataflow to initializing a cipher with a static initialization vector.
 */
private class StaticInitializationVectorConfig extends TaintTracking::Configuration {
  StaticInitializationVectorConfig() { this = "StaticInitializationVectorConfig" }

  override predicate isSource(DataFlow::Node source) {
    source instanceof StaticInitializationVectorSource
  }

  override predicate isSink(DataFlow::Node sink) { sink instanceof EncryptionInitializationSink }

  override predicate isAdditionalTaintStep(DataFlow::Node fromNode, DataFlow::Node toNode) {
    createInitializationVectorSpecStep(fromNode, toNode)
  }

  override predicate isSanitizer(DataFlow::Node node) {
    exists(ArrayUpdate update | update.getArray() = node.asExpr())
  }
}

from DataFlow::PathNode source, DataFlow::PathNode sink, StaticInitializationVectorConfig conf
where conf.hasFlowPath(source, sink)
select sink.getNode(), source, sink, "A $@ should not be used for encryption.", source.getNode(),
  "static initialization vector"
