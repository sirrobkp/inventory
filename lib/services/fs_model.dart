/// Format-neutral model of the financial statements pack. One builder produces this;
/// three renderers (PDF, Word, Excel) turn it into files.
abstract class Block {
  const Block();
}

class BTitle extends Block {
  const BTitle(this.text);
  final String text;
}

class BHead extends Block {
  const BHead(this.text);
  final String text;
}

class BSub extends Block {
  const BSub(this.text);
  final String text;
}

class BPara extends Block {
  const BPara(this.text, {this.size = 9.5, this.bold = false, this.center = false});
  final String text;
  final double size;
  final bool bold, center;
}

class BRow extends Block {
  const BRow(this.label, this.value, {this.bold = false, this.indent = 0, this.topLine = false});
  final String label, value;
  final bool bold, topLine;
  final int indent;
}

class BTable extends Block {
  const BTable(this.headers, this.data);
  final List<String> headers;
  final List<List<String>> data;
}

class BGap extends Block {
  const BGap([this.h = 8]);
  final double h;
}

class Section {
  Section(this.name, this.blocks);
  final String name;
  final List<Block> blocks;
}

class FsDoc {
  FsDoc({required this.company, required this.periodTitle, required this.tag, required this.cover, required this.sections});
  final String company, periodTitle, tag;
  final List<String> cover; // cover page lines (first = company name)
  final List<Section> sections;
}
